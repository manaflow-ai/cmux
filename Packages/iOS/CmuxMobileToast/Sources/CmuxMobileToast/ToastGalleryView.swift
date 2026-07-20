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

    /// With `CMUX_TOAST_GALLERY_AUTORUN=1`, runs the passthrough probe and
    /// then the shared ``ToastDemo`` script so a screen recording captures
    /// every arrival, departure, coalescing bump, and queue advance without
    /// UI driving.
    private func runAutodemoIfRequested() async {
        guard ProcessInfo.processInfo.environment["CMUX_TOAST_GALLERY_AUTORUN"] == "1" else { return }
        #if os(iOS)
        let clock = ContinuousClock()
        func pause(_ seconds: Double) async {
            try? await clock.sleep(for: .seconds(seconds))
        }
        await pause(2)
        await recordPassthroughProbe(pause: pause)
        #endif
        ToastDemo.run(on: toasts)
    }

    #if os(iOS)
    /// Exercises the passthrough window's `hitTest` with real on-device
    /// geometry and writes the verdicts to Documents/toast-probe.txt: with no
    /// toast the overlay must return nil everywhere (UIKit then routes the
    /// touch to the app's window below); with a toast visible, the card region
    /// must resolve to a live view while the rest still falls through.
    private func recordPassthroughProbe(pause: (Double) async -> Void) async {
        var lines: [String] = []
        defer {
            let url = URL.documentsDirectory.appending(path: "toast-probe.txt")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        guard let overlay = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: { $0 is ToastPassthroughWindow }) else {
            lines.append("FAIL overlay window not found")
            return
        }
        let center = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
        let empty = overlay.hitTest(center, with: nil)
        lines.append(empty == nil
            ? "PASS empty overlay passes touches through (hitTest nil)"
            : "FAIL empty overlay captured touch: \(type(of: empty!))")

        toasts.present(.info("Passthrough probe", coalescingKey: "probe"))
        await pause(0.8)
        lines.append("presented=\(String(describing: toasts.presented?.toast.message)) safeTop=\(overlay.safeAreaInsets.top)")
        var hitAny = false
        for y in stride(from: 4, through: 120, by: 8) {
            let point = CGPoint(x: overlay.bounds.midX, y: overlay.safeAreaInsets.top + CGFloat(y))
            if let hit = overlay.hitTest(point, with: nil) {
                hitAny = true
                lines.append("hit y=+\(y): \(type(of: hit))")
            }
        }
        lines.append(hitAny
            ? "PASS toast region captures touch"
            : "FAIL toast region did not hit-test at any scanned point")
        let besideToast = overlay.hitTest(center, with: nil)
        lines.append(besideToast == nil
            ? "PASS area beside visible toast still passes through"
            : "FAIL area beside toast captured: \(type(of: besideToast!))")
        toasts.dismissAll()
        await pause(0.8)
    }
    #endif
}
#endif
