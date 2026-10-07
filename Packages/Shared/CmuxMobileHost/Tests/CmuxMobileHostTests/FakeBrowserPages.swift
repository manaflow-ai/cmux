import CmuxBrowserStream
import CmuxMobileHost
import CmuxLink
import CmuxMobileLink
import CmuxMobileWire
import CryptoKit
import Foundation

/// A Mac with one browser tab, a 1440x900 pt page at 2x.
final class FakeBrowserPages: BrowserPageHost {
    let attachment = FakeBrowserAttachment()
    let tabs: Set<String>

    init(tabs: Set<String> = ["tab_b1"]) {
        self.tabs = tabs
    }

    func attach(_ request: BrowserAttachRequest) async throws -> any BrowserPageAttachment {
        guard tabs.contains(request.tab) else { throw BrowserPageError.tabNotFound }
        await attachment.attached(request)
        return attachment
    }
}

actor FakeBrowserAttachment: BrowserPageAttachment {
    nonisolated let source = FakeVideoSource()
    nonisolated var video: any BrowserVideoSource { source }
    var geometry = BrowserPageGeometry(cssWidth: 1440, cssHeight: 900, backingScale: 2)
    private(set) var requests: [BrowserAttachRequest] = []
    private(set) var inputs: [RbInputEvent] = []
    private(set) var loads: [URL] = []
    private(set) var histories: [RbHistoryOp] = []
    private(set) var pasteboards: [[RbClipboardItem]] = []
    private(set) var detached = false
    private var continuation: AsyncStream<BrowserPageEvent>.Continuation?
    nonisolated let inputCount = CountSignal()

    func attached(_ request: BrowserAttachRequest) {
        requests.append(request)
    }

    func events() -> AsyncStream<BrowserPageEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: BrowserPageEvent.self)
        continuation.yield(.page(RbPage(url: "https://example.com/", title: "Example", canGoBack: true)))
        self.continuation = continuation
        return stream
    }

    func emit(_ event: BrowserPageEvent) {
        continuation?.yield(event)
    }

    func apply(_ input: RbInputEvent) async {
        inputs.append(input)
        await inputCount.increment()
    }

    func waitForInputs(_ count: Int) async {
        await inputCount.wait(atLeast: count)
    }

    func load(_ url: URL) { loads.append(url) }
    func history(_ op: RbHistoryOp) { histories.append(op) }
    func pasteboard(_ items: [RbClipboardItem]) { pasteboards.append(items) }
    func setVisible(_ visible: Bool) {}
    func detach() { detached = true }
}

/// A video source the test drives: `push` makes the next frame; a keyframe
/// request re-emits the last content as a keyframe.
actor FakeVideoSource: BrowserVideoSource {
    private var queue: [Data] = []
    private var last = Data([0])
    private var keyframeRequested = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var pulls = 0
    private(set) var keyframeRequests = 0
    private(set) var requestsSeen: [BrowserFrameRequest] = []
    nonisolated let pullCount = CountSignal()
    nonisolated let keyframeCount = CountSignal()

    func push(_ content: Data) {
        queue.append(content)
        wake()
    }

    func nextFrame(_ request: BrowserFrameRequest) async throws -> BrowserEncodedFrame? {
        pulls += 1
        requestsSeen.append(request)
        await pullCount.increment()
        while queue.isEmpty, !keyframeRequested {
            try Task.checkCancellation()
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter = $0 }
            } onCancel: {
                Task { await self.wake() }
            }
        }
        let key = keyframeRequested
        keyframeRequested = false
        let content = queue.isEmpty ? last : queue.removeFirst()
        last = content
        return BrowserEncodedFrame(accessUnit: Data([key ? 0x65 : 0x41]) + content, isKeyframe: key,
                                   captureMicros: UInt64(pulls), pixelWidth: request.pixelWidth, pixelHeight: request.pixelHeight)
    }

    func requestKeyframe() async {
        keyframeRequests += 1
        keyframeRequested = true
        wake()
        await keyframeCount.increment()
    }

    func waitForPulls(_ count: Int) async {
        await pullCount.wait(atLeast: count)
    }

    func waitForKeyframeRequests(_ count: Int) async {
        await keyframeCount.wait(atLeast: count)
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }
}

/// The harness's paired key as the phone's hello signer.
struct HarnessSigner: MobileDeviceSigner {
    let key: P256.Signing.PrivateKey
    let install = PhoneHarness.install
    let keyID = "k1"

    func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}

extension PhoneHarness {
    /// The phone's one `MobileLinkClient` for this Mac, over the harness network.
    func linkClient() -> MobileLinkClient {
        let carrier = network.carrier(kind: .direct, path: .direct)
        return MobileLinkClient(
            hostID: Self.hostID, signer: HarnessSigner(key: key),
            client: HelloClient(install: Self.install, platform: "ios", appVersion: "1.0"),
            makeSession: {
                LinkSession(peer: LinkPeer(hostID: Self.hostID),
                            selector: PathSelector(carriers: [carrier],
                                                   policy: PathPolicy(preferenceWindow: .milliseconds(5), upgradeRetry: nil)),
                            configuration: Self.fast)
            })
    }
}
