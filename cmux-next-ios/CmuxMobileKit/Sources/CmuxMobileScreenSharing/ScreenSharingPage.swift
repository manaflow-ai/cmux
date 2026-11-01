#if os(iOS)
public import CmuxDeviceHub
import CmuxMobileDesign
import CmuxScreenKit
import CmuxScreenKitUI
public import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Settings → Screen Sharing: the account's Macs (from the device hub), the
/// viewer's choices, and the full-screen viewer of the Mac being shared. A
/// Mac shares its screen from its own Settings › Devices; the first time this
/// phone asks, the Mac shows Allow / Deny.
public struct ScreenSharingPage: View {
    let service: ScreenSharingService

    public init(service: ScreenSharingService) {
        self.service = service
    }

    public var body: some View {
        List {
            statusSection
            macsSection
            ScreenSharingViewerSettings(preferences: service.preferences)
        }
        .navigationTitle("Screen Sharing")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await service.refresh() }
        .onAppear { service.start() }
        .fullScreenCover(item: Binding(get: { service.viewer }, set: { if $0 == nil { service.dismissViewer() } })) { viewer in
            ScreenSharingViewerScreen(viewer: viewer, retry: { viewer.request(viewer.lastScope) },
                                      close: { service.dismissViewer() })
        }
        .accessibilityIdentifier("screenSharing.page")
    }

    @ViewBuilder private var statusSection: some View {
        switch service.status {
        case .idle, .starting:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to your devices…").foregroundStyle(theme.colors.label2)
                }
            }
        case let .failed(message):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your devices can't be reached").font(theme.type.rowTitle)
                    Text(message).font(theme.type.meta).foregroundStyle(theme.colors.label2).lineLimit(3)
                }
                Button("Try Again") { Task { await service.refresh() } }
            }
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder private var macsSection: some View {
        let macs = service.macs
        Section {
            if macs.isEmpty, service.status == .ready {
                Text("No Macs. Sign in to cmux on your Mac with this account, then turn on Share This Mac in its Settings › Devices.")
                    .font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2)
            }
            ForEach(macs) { mac in
                ScreenSharingMacRow(mac: mac, access: service.access(to: mac)) { scope in
                    service.connect(to: mac, scope: scope ?? service.preferences.defaultScope)
                }
            }
        } header: {
            Text("Your Macs")
        } footer: {
            Text("A Mac asks before it shares the first time. You can change what this iPhone may do on the Mac in its Settings › Devices.")
        }
    }
}

/// One Mac: its name, whether it can be shared now, and this phone's access to it.
struct ScreenSharingMacRow: View {
    let mac: HubDevice
    let access: DeviceScope
    /// Connect; nil asks for the default scope.
    let connect: (SessionScope?) -> Void

    private var available: Bool { mac.online && mac.macScreenShared && access != .none }

    var body: some View {
        Button { connect(nil) } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(theme.type.rowTitle)
                    .foregroundStyle(available ? theme.colors.label : theme.colors.label2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.name).font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
                    Text(status).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                }
                Spacer(minLength: 8)
                if available {
                    Image(systemName: "chevron.right").font(theme.type.meta).foregroundStyle(theme.colors.label2)
                }
            }
        }
        .disabled(!available)
        .contextMenu {
            Button("Connect with Full Control", systemImage: "cursorarrow.click.2") { connect(.full) }
            Button("Connect View Only", systemImage: "eye") { connect(.view) }
        }
        .accessibilityIdentifier("screenSharing.mac.\(mac.name)")
    }

    private var status: String {
        guard mac.online else { return String(localized: "Offline") }
        guard mac.macScreenShared else { return String(localized: "Not shared") }
        switch access {
        case .none: return String(localized: "Blocked for this iPhone")
        case .view: return String(localized: "Sharing · View Only")
        case .full: return String(localized: "Sharing · Full Control")
        case .ask: return String(localized: "Sharing · Asks first")
        }
    }
}

/// The viewer's choices (Settings → Screen Sharing → Viewer).
struct ScreenSharingViewerSettings: View {
    let preferences: ScreenSharingPreferences

    var body: some View {
        @Bindable var preferences = preferences
        Section {
            Picker("Connect with", selection: $preferences.defaultScope) {
                Text("Full Control").tag(SessionScope.full)
                Text("View Only").tag(SessionScope.view)
            }
            Picker("Touch", selection: $preferences.defaults.inputMode) {
                ForEach(ScreenInputMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .accessibilityIdentifier("screenSharing.inputMode")
            Picker("Quality", selection: $preferences.defaults.quality) {
                ForEach(ScreenQuality.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Fit to Display", isOn: $preferences.defaults.fitToDisplay)
            Toggle("Show Stats", isOn: $preferences.defaults.showStats)
        } header: {
            Text("Viewer")
        } footer: {
            Text("Full Control lets this iPhone click and type on the Mac. Direct Touch clicks where you touch; Trackpad moves a pointer like a MacBook trackpad. Quality Auto keeps text sharp and lowers the frame rate on a slow network.")
        }
    }
}

/// The full-screen viewer: the Mac's screen once approved, else the card for
/// where the request is (waiting for the Mac, declined, refused, ended).
struct ScreenSharingViewerScreen: View {
    let viewer: ScreenSharingViewer
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        Group {
            if let screen = viewer.screen {
                // No .resumeOnForeground: a ticket admits once, so a dropped stream cannot
                // reconnect; the viewer ends it and its card asks the Mac again.
                ScreenSessionView(session: screen, features: Self.features, close: close)
            } else {
                card.background(theme.colors.bg.color.ignoresSafeArea())
            }
        }
        .onAppear { ScreenSharingOrientation.shared.begin() }
        .onDisappear { ScreenSharingOrientation.shared.end() }
    }

    static let features = ScreenFeatures.all.subtracting(.resumeOnForeground)

    @ViewBuilder private var card: some View {
        switch viewer.phase {
        case .idle, .requesting, .approved:
            EmptyState(symbol: "desktopcomputer", title: "Connecting to \(viewer.hostName)…",
                       secondaryTitle: "Cancel", secondary: close)
        case .waitingForApproval:
            EmptyState(symbol: "hand.raised", title: "Waiting for \(viewer.hostName)",
                       message: "Allow this iPhone on the Mac to start sharing.", secondaryTitle: "Cancel", secondary: close)
        case .streaming:
            EmptyState(symbol: "desktopcomputer", title: "Starting the screen…", secondaryTitle: "Close", secondary: close)
        case .declined:
            EmptyState(symbol: "hand.raised.slash", title: "\(viewer.hostName) declined",
                       message: "Someone at the Mac said Deny.", primaryTitle: "Ask Again", primary: retry,
                       secondaryTitle: "Close", secondary: close)
        case let .refused(refusal, _):
            EmptyState(symbol: "exclamationmark.triangle", title: refusal.title(viewer.hostName), message: refusal.message,
                       primaryTitle: refusal == .other || refusal == .hostOffline ? "Try Again" : nil, primary: retry,
                       secondaryTitle: "Close", secondary: close)
        case let .ended(reason):
            EmptyState(symbol: "rectangle.on.rectangle.slash", title: "Sharing ended",
                       message: LocalizedStringKey(ScreenSharingEndCopy.message(reason, host: viewer.hostName)),
                       primaryTitle: "Connect Again", primary: retry, secondaryTitle: "Close", secondary: close)
        }
    }
}

extension ScreenSharingRefusal {
    func title(_ host: String) -> LocalizedStringKey {
        switch self {
        case .permissionNone: "\(host) doesn't allow this iPhone"
        case .viewOnly: "\(host) allows View Only"
        case .hostOffline: "\(host) is offline"
        case .notShared: "\(host) isn't sharing its screen"
        case .notFound: "\(host) isn't one of your devices"
        case .other: "Couldn't reach \(host)"
        }
    }

    var message: LocalizedStringKey? {
        switch self {
        case .permissionNone: "Change this iPhone's access on the Mac, in Settings › Devices."
        case .viewOnly: "Connect View Only, or allow Full Control on the Mac."
        case .hostOffline: "Open cmux on the Mac and make sure it's online."
        case .notShared: "Turn on Share This Mac in the Mac's Settings › Devices."
        case .notFound: nil
        case .other: "Check your connection and try again."
        }
    }
}

/// What the ended card says for the hub's end reasons (PROTOCOL.md, End reasons).
enum ScreenSharingEndCopy {
    static func message(_ reason: String?, host: String) -> String {
        switch reason {
        case "host_stopped": String(localized: "\(host) stopped sharing.")
        case "sharing_off": String(localized: "\(host) turned off Share This Mac.")
        case "permission_revoked": String(localized: "\(host) changed this iPhone's access.")
        case "peer_offline": String(localized: "\(host) went offline.")
        case "signed_out", "device_removed:host": String(localized: "\(host) signed out.")
        case "device_removed:viewer": String(localized: "This iPhone was removed from your devices.")
        case "expired": String(localized: "Nobody answered on \(host).")
        case "failed": String(localized: "The connection to \(host) dropped.")
        default: String(localized: "The session with \(host) is over.")
        }
    }
}
#endif
