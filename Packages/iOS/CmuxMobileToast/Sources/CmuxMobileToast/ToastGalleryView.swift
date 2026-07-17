#if DEBUG
public import SwiftUI

/// DEBUG-only exercise screen for the toast system: every style, composition,
/// and queue/coalesce behavior behind one button each. Mounted by the root
/// scene when `CMUX_TOAST_GALLERY=1`; also the surface UI tests drive.
/// Dev-facing only, so strings are intentionally unlocalized.
public struct ToastGalleryView: View {
    @Environment(ToastCenter.self) private var toasts
    @State private var uniqueCounter = 0

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("Styles") {
                    Button("Success") {
                        toasts.present(.success("Workspace created"))
                    }
                    .accessibilityIdentifier("ToastGallerySuccess")
                    Button("Failure with title") {
                        toasts.present(.failure(
                            "Not connected to your Mac.",
                            title: "Couldn't rename workspace"
                        ))
                    }
                    .accessibilityIdentifier("ToastGalleryFailure")
                    Button("Warning") {
                        toasts.present(.warning("This Mac is running an older cmux build."))
                    }
                    Button("Info") {
                        toasts.present(.info("Agent finished in workspace api-fix"))
                    }
                    .accessibilityIdentifier("ToastGalleryInfo")
                    Button("Info with icon") {
                        toasts.present(.info("Copied to clipboard", systemImage: "doc.on.doc"))
                    }
                }
                Section("Composition") {
                    Button("With action") {
                        toasts.present(.failure(
                            "The request timed out.",
                            title: "Couldn't create workspace",
                            action: Toast.Action(label: "Retry") {}
                        ))
                    }
                    .accessibilityIdentifier("ToastGalleryAction")
                    Button("Long message") {
                        toasts.present(.failure(
                            "The connection to your Mac was interrupted while the workspace list was refreshing, so the latest changes may not be shown until it reconnects.",
                            title: "Sync interrupted"
                        ))
                    }
                    Button("Persistent") {
                        toasts.present(.warning(
                            "Reconnecting to your Mac…",
                            autoDismiss: .never,
                            coalescingKey: "gallery.persistent"
                        ))
                    }
                    Button("Bottom placement") {
                        toasts.present(.success("Saved", placement: .bottom))
                    }
                    .accessibilityIdentifier("ToastGalleryBottom")
                }
                Section("Behavior") {
                    Button("Queue three") {
                        toasts.present(.success("First: workspace created"))
                        toasts.present(.info("Second: agent finished"))
                        toasts.present(.warning("Third: build is out of date"))
                    }
                    .accessibilityIdentifier("ToastGalleryQueue")
                    Button("Coalesce (tap repeatedly)") {
                        toasts.present(.failure(
                            "Not connected to your Mac.",
                            title: "Couldn't pin workspace"
                        ))
                    }
                    .accessibilityIdentifier("ToastGalleryCoalesce")
                    Button("Unique spam") {
                        uniqueCounter += 1
                        toasts.present(.info("Notice #\(uniqueCounter)"))
                    }
                    Button("Dismiss all") {
                        toasts.dismissAll()
                    }
                }
            }
            .navigationTitle("Toasts")
        }
        .task { await runAutodemoIfRequested() }
    }

    /// With `CMUX_TOAST_GALLERY_AUTORUN=1`, walks the full toast vocabulary on
    /// a fixed cadence so a screen recording captures every arrival,
    /// departure, coalescing bump, and queue advance without UI driving.
    /// Demo pacing only (DEBUG harness), hence the deliberate wall-clock sleeps.
    private func runAutodemoIfRequested() async {
        guard ProcessInfo.processInfo.environment["CMUX_TOAST_GALLERY_AUTORUN"] == "1" else { return }
        let clock = ContinuousClock()
        func pause(_ seconds: Double) async {
            try? await clock.sleep(for: .seconds(seconds))
        }

        await pause(2)
        toasts.present(.success("Workspace created"))
        await pause(5.5)

        toasts.present(.failure(
            "Not connected to your Mac.",
            title: "Couldn't rename workspace",
            coalescingKey: "demo.error"
        ))
        await pause(2)
        toasts.present(.failure(
            "Not connected to your Mac.",
            title: "Couldn't rename workspace",
            coalescingKey: "demo.error"
        ))
        await pause(7.5)

        toasts.present(.success("First: workspace created"))
        toasts.present(.info("Second: agent finished"))
        toasts.present(.warning("Third: build is out of date"))
        await pause(13)

        toasts.present(.info("Copied to clipboard", systemImage: "doc.on.doc"))
        await pause(4.5)
        toasts.present(.success("Saved", placement: .bottom))
        await pause(5)

        toasts.present(.failure(
            "The request timed out.",
            title: "Couldn't create workspace",
            action: Toast.Action(label: "Retry") {}
        ))
        await pause(7.5)
        toasts.dismissAll()
    }
}
#endif
