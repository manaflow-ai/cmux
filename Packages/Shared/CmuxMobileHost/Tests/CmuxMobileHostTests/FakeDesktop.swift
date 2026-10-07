import CmuxBrowserStream
import CmuxLink
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import CmuxRemoteDesktop
import Foundation

/// A Mac with two displays and two windows; every open makes a `FakeDesktopTarget`.
actor FakeDesktopSources: RemoteDesktopSources {
    static let main = DesktopDisplay(id: 1, name: "Built-in", width: 3024, height: 1964, scale: 2, isMain: true)
    static let studio = DesktopDisplay(id: 2, name: "Studio", width: 5120, height: 2880, scale: 2, isMain: false)

    private(set) var opens: [RemoteDesktopOpenRequest] = []
    private(set) var targets: [FakeDesktopTarget] = []
    nonisolated let openCount = CountSignal()

    func displays() -> [DesktopDisplay] { [Self.main, Self.studio] }

    func windows() -> [DesktopWindow] { [DesktopWindow(id: 812, app: "Simulator", title: "iPhone 17")] }

    func describe(_ target: DesktopTarget) throws -> DesktopTargetInfo {
        switch target {
        case .display(let id):
            guard let display = displays().first(where: { id == nil ? $0.isMain : $0.id == id }) else {
                throw RemoteDesktopSourceError.displayNotFound
            }
            return DesktopTargetInfo(kind: .display, width: display.width, height: display.height, scale: display.scale,
                                     name: display.name)
        case .window(let id):
            guard id == 812 else { throw RemoteDesktopSourceError.windowNotFound }
            return DesktopTargetInfo(kind: .window, width: 800, height: 1600, scale: 2, name: "iPhone 17")
        case .vnc(let address):
            return DesktopTargetInfo(kind: .vnc, width: 0, height: 0, scale: 1, name: address.host)
        }
    }

    func open(_ request: RemoteDesktopOpenRequest) async throws -> any RemoteDesktopTarget {
        let target = FakeDesktopTarget(info: try describe(request.target), region: request.region)
        opens.append(request)
        targets.append(target)
        await openCount.increment()
        return target
    }

    func target(_ index: Int) -> FakeDesktopTarget? {
        index < targets.count ? targets[index] : nil
    }
}

actor FakeDesktopTarget: RemoteDesktopTarget {
    nonisolated let source = FakeVideoSource()
    nonisolated var video: any BrowserVideoSource { source }
    nonisolated var cursor: RemoteDesktopChannelOpened.Cursor { .local }
    nonisolated let inputCount = CountSignal()
    nonisolated let regionCount = CountSignal()
    nonisolated let pushCount = CountSignal()
    private let targetInfo: DesktopTargetInfo
    private(set) var inputs: [RdInputEvent] = []
    private(set) var regions: [DesktopRect] = []
    private(set) var pushed: [String] = []
    private(set) var passwords: [String] = []
    private(set) var closed = false
    private let stream: AsyncStream<RemoteDesktopTargetEvent>
    private let continuation: AsyncStream<RemoteDesktopTargetEvent>.Continuation

    init(info: DesktopTargetInfo, region: DesktopRect) {
        targetInfo = info
        regions = [region]
        (stream, continuation) = AsyncStream.makeStream(of: RemoteDesktopTargetEvent.self)
    }

    func info() -> DesktopTargetInfo { targetInfo }

    func setRegion(_ rect: DesktopRect) async {
        regions.append(rect)
        await regionCount.increment()
    }

    func apply(_ event: RdInputEvent) async {
        inputs.append(event)
        await inputCount.increment()
    }

    func pushClipboard(_ text: String) async {
        pushed.append(text)
        await pushCount.increment()
    }

    func readClipboard() -> String? { "mac text" }

    func authenticate(password: String) { passwords.append(password) }

    func events() -> AsyncStream<RemoteDesktopTargetEvent> { stream }

    func emit(_ event: RemoteDesktopTargetEvent) { continuation.yield(event) }

    func close() {
        closed = true
        continuation.finish()
    }
}

struct FakePermissions: RemoteDesktopPermissions {
    var screenRecording = true
    var accessibility = true

    func isGranted(_ permission: RemoteDesktopPermission) async -> Bool {
        switch permission {
        case .screenRecording: screenRecording
        case .accessibility: accessibility
        }
    }
}

/// Answers consent requests with `answer`, or never (until cancelled) when nil.
actor FakeConsent: RemoteDesktopConsent {
    private let answer: Bool?
    private(set) var requests: [RemoteDesktopConsentRequest] = []
    private(set) var cancelled = 0

    init(answer: Bool?) {
        self.answer = answer
    }

    func request(_ request: RemoteDesktopConsentRequest) async -> Bool {
        requests.append(request)
        if let answer { return answer }
        // Nobody answers; the session's timeout or the phone leaving cancels us.
        try? await Task.sleep(for: .seconds(3600))
        cancelled += 1
        return false
    }
}

actor FakeIndicator: RemoteDesktopIndicator {
    private(set) var sessions: [RemoteDesktopIndicatorSession] = []
    private(set) var handles: [FakeIndicatorHandle] = []
    nonisolated let beginCount = CountSignal()

    func begin(_ session: RemoteDesktopIndicatorSession) async -> any RemoteDesktopIndicatorHandle {
        let handle = FakeIndicatorHandle()
        sessions.append(session)
        handles.append(handle)
        await beginCount.increment()
        return handle
    }

    func handle(_ index: Int) -> FakeIndicatorHandle? {
        index < handles.count ? handles[index] : nil
    }
}

final class FakeIndicatorHandle: RemoteDesktopIndicatorHandle, Sendable {
    let stopRequests: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    let state = IndicatorState()

    init() {
        (stopRequests, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    /// The person at the Mac presses Stop.
    func pressStop() {
        continuation.yield()
    }

    func update(mode: DesktopMode) async {
        await state.record(mode)
    }

    func end() async {
        await state.end()
    }
}

actor IndicatorState {
    private(set) var modes: [DesktopMode] = []
    private(set) var ended = false

    func record(_ mode: DesktopMode) { modes.append(mode) }
    func end() { ended = true }
}

/// The phone opener over the harness link (odd A0 ids from 1).
struct HarnessDesktopOpener: RemoteDesktopChannelOpener {
    let link: LinkSession
    let ids = ChannelIDs()

    func openChannel(_ request: MobileChannelRequest) async throws -> MobileOpenedChannel {
        let id = await ids.take()
        let channel = MobileChannel(id: id, link: try await link.openChannel(
            ChannelDescriptor(stream: request.stream, reliability: .reliableOrdered, priority: request.priority)))
        try await channel.send(frame: .channelOpen(ChannelOpenFrame(channel: id, kind: request.kind, channelClass: request.channelClass,
                                                                    window: request.window, params: request.params)))
        guard case .json(let value) = await channel.receive(), let frame = try? MobileFrame(value: value) else {
            throw MobileLinkClientError.linkLost
        }
        switch frame {
        case .channelOpened(let opened): return MobileOpenedChannel(channel: channel, opened: opened, generation: 1)
        case .channelRefused(let refused):
            throw MobileLinkClientError.refused(code: refused.code, message: refused.message, retryable: refused.retryable)
        default: throw MobileLinkClientError.protocolViolation("unexpected")
        }
    }

    func openDatagramLane(pairedWith channel: MobileOpenedChannel) async throws -> MobileDatagramLane {
        try await MobileDatagramLane.open(on: link, pairedWith: channel.channel.id)
    }
}

/// Collects a desktop client's events in the background.
actor DesktopEventLog {
    private(set) var events: [RemoteDesktopEvent] = []
    nonisolated let count = CountSignal()

    func start(_ stream: AsyncStream<RemoteDesktopEvent>) {
        Task { [weak self] in
            for await event in stream { await self?.append(event) }
        }
    }

    func waitFor(_ match: @escaping @Sendable (RemoteDesktopEvent) -> Bool) async {
        var seen = 0
        while true {
            if events.contains(where: match) { return }
            seen = events.count
            await count.wait(atLeast: seen + 1)
        }
    }

    private func append(_ event: RemoteDesktopEvent) async {
        events.append(event)
        await count.increment()
    }
}

import CmuxLinkTesting

/// A manual clock and its LinkClock.
struct ManualClockBox {
    let clock = ManualClock()
    var link: LinkClock { LinkClock(clock) }
}
