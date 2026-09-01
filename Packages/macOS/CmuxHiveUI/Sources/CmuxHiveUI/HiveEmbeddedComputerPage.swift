public import CmuxHive
public import SwiftUI

/// Hosts a remote computer's live viewer inside the main window's content
/// area (the `computers.presentation = sidebar` mode) — the same
/// session/list/pane stack the auxiliary viewer window shows, minus the
/// window.
///
/// The session comes from an injected async provider (the app caches one
/// session per device), so switching computer scope back and forth reuses
/// the existing connection instead of re-dialing.
public struct HiveEmbeddedComputerPage: View {
    private let deviceID: String
    private let sessionProvider: @MainActor (String) async -> HiveRemoteMacSession?
    @State private var session: HiveRemoteMacSession?
    @State private var failedToStart = false

    /// Creates the embedded page for one computer.
    /// - Parameters:
    ///   - deviceID: The paired computer's registry device id.
    ///   - sessionProvider: Returns the (cached) live session for a device,
    ///     or `nil` when the pairing is missing.
    public init(
        deviceID: String,
        sessionProvider: @escaping @MainActor (String) async -> HiveRemoteMacSession?
    ) {
        self.deviceID = deviceID
        self.sessionProvider = sessionProvider
    }

    public var body: some View {
        Group {
            if let session {
                HiveViewerRootView(session: session)
            } else if failedToStart {
                ContentUnavailableView(
                    String(localized: "hive.embedded.unavailable", defaultValue: "Computer Unavailable"),
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                    description: Text(String(
                        localized: "hive.embedded.unavailable.detail",
                        defaultValue: "This computer isn't paired anymore. Pair it again in Settings › Computers."
                    ))
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: deviceID) {
            failedToStart = false
            session = await sessionProvider(deviceID)
            failedToStart = session == nil
        }
    }
}
