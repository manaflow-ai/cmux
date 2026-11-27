#if os(iOS)
public import CmuxDeviceHub
public import CmuxMobileBrowserStream
import CmuxMobileDesign
import CmuxSpinner
public import Foundation
public import Observation
public import SwiftUI

/// A Mac this phone holds a cmux-wg link to, as Screen Sharing matches it to a device hub Mac.
public struct ScreenSharingLinkedMac: Equatable, Sendable {
    /// The link's Mac id (the presence registry's, not the device hub's).
    public var macID: String
    public var name: String
    /// What the Mac's host listed in `version` (nil: not known yet).
    public var capabilities: Set<String>?

    public init(macID: String, name: String, capabilities: Set<String>?) {
        self.macID = macID
        self.name = name
        self.capabilities = capabilities
    }
}

/// Which way Screen Sharing shows a Mac: the device hub's WebRTC session (the default), or,
/// with Settings → Transport → Mac Screen over Link on, the Mac's display as rd/1 on the link
/// this phone already holds (`surface` tab `d~0`, view only), when that Mac lists
/// `mac-display-v1` (cmux-next-ios/PROTOCOL.md `surface`).
@MainActor
public enum ScreenSharingLinkRoute {
    /// The capability a Mac's host lists when it streams its own displays on the link.
    public static let capability = StreamedBrowserDirectory.macDisplayCapability

    /// The `surface` tab of the Mac's main display.
    public static let mainDisplayTab = StreamedBrowserDirectory.macDisplayTab(display: 0)

    /// Whether the setting is on (off by default; read when a Mac is opened).
    static func settingOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: CmuxMobilePreferences.Key.macScreenOverLink)
    }

    /// Whether a Mac that listed `capabilities` streams its screen on the link.
    public static func streamsDisplay(_ capabilities: Set<String>?) -> Bool {
        capabilities?.contains(capability) == true
    }

    /// The link Mac to show the hub Mac named `name` from, or nil for the WebRTC path: the
    /// setting is on and exactly one linked Mac has that name (the hub and the link name a Mac
    /// alike; `ScreenSharingPage.normalized`) and lists `mac-display-v1`.
    public static func linkMac(named name: String, settingOn: Bool, linked: [ScreenSharingLinkedMac]) -> String? {
        guard settingOn, let wanted = ScreenSharingPage.normalized(name) else { return nil }
        let named = linked.filter { ScreenSharingPage.normalized($0.name) == wanted }
        guard named.count == 1, let mac = named.first, streamsDisplay(mac.capabilities) else { return nil }
        return mac.macID
    }
}

/// One Mac's screen shown over its link, view only: nothing the phone does reaches the Mac.
/// A refusal or end of the stream, or no picture within ``firstFrameDeadline``, hands the Mac
/// back to the WebRTC path (``ScreenSharingService``'s fallback).
@MainActor @Observable
public final class ScreenSharingLinkViewer: Identifiable {
    public nonisolated var id: String { "link:\(hostID)" }
    public nonisolated let hostID: String
    public let hostName: String
    /// The hub's Mac and the scope the tap asked for: the fallback asks the hub with them.
    let mac: HubDevice
    let scope: SessionScope
    public let stream: StreamedBrowserModel
    /// Why the link stream failed (nil: it hasn't).
    public private(set) var failure: String?

    /// How long the stream has to show its first picture before the WebRTC path takes over.
    @ObservationIgnored var firstFrameDeadline: Duration = .seconds(10)
    /// Called once when the stream fails (the service falls back).
    @ObservationIgnored var onFailure: @MainActor (ScreenSharingLinkViewer) -> Void = { _ in }
    /// Closed for the background: the Mac stops capturing, and its close is not a failure.
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var deadline: Task<Void, Never>?

    init(mac: HubDevice, scope: SessionScope, stream: StreamedBrowserModel) {
        hostID = mac.id
        hostName = mac.name
        self.mac = mac
        self.scope = scope
        self.stream = stream
    }

    /// The stream's refusal or end (`RefusalSink`): the link path failed.
    func refused(_ code: String) {
        guard !paused else { return }
        fail(code)
    }

    func fail(_ reason: String) {
        guard !closed, failure == nil else { return }
        failure = reason
        deadline?.cancel()
        onFailure(self)
    }

    /// Starts the first-picture deadline (the screen calls it when it shows).
    func startDeadline() {
        guard deadline == nil, !closed else { return }
        let wait = firstFrameDeadline
        // task-owner: one deadline per viewer; cancelled when it closes or fails
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            guard let self, !self.closed, self.stream.meter.frames == 0 else { return }
            self.fail("no_picture")
        }
    }

    /// The app went to the background (the Mac stops capturing) or came back.
    func setActive(_ active: Bool) {
        guard !closed else { return }
        stream.setAppActive(active)
        if active {
            paused = false
            stream.reconnect()
        } else {
            paused = true
            stream.close()
        }
    }

    /// Closed by the person, the service, or the fallback: no more failures are reported.
    func close() {
        closed = true
        deadline?.cancel()
        deadline = nil
        stream.close()
    }
}

/// The full-screen Mac screen over the link: the picture, a spinner until it comes, and Close.
struct ScreenSharingLinkScreen: View {
    let viewer: ScreenSharingLinkViewer
    let close: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            StreamedViewOnlySurface(model: viewer.stream, label: String(localized: "Screen of \(viewer.hostName)"),
                                    identifier: "screenSharing.link.screen")
                .allowsHitTesting(false)
                .ignoresSafeArea()
            if viewer.stream.meter.frames == 0 {
                CmuxSpinner(tint: .white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button("Close", action: close)
                .buttonStyle(.borderedProminent)
                .tint(.black.opacity(0.6))
                .padding()
                .accessibilityIdentifier("screenSharing.link.close")
        }
        .onAppear {
            ScreenSharingOrientation.shared.begin()
            viewer.stream.setAppActive(scenePhase == .active)
            viewer.stream.setVisible(true)
            viewer.stream.reconnect()
            viewer.startDeadline()
        }
        .onDisappear {
            ScreenSharingOrientation.shared.end()
            viewer.stream.setVisible(false)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { viewer.setActive(false) } else if phase == .active { viewer.setActive(true) }
        }
    }
}

/// What Screen Sharing shows full screen: the hub's viewer, or a Mac's screen over its link.
enum ScreenSharingScreen: Identifiable {
    case hub(ScreenSharingViewer)
    case link(ScreenSharingLinkViewer)

    var id: String {
        switch self {
        case let .hub(viewer): "hub:\(viewer.hostID)"
        case let .link(viewer): viewer.id
        }
    }
}
#endif
