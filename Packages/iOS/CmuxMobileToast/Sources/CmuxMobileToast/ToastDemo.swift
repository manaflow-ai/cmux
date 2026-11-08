#if DEBUG
public import Foundation

/// DEBUG-only scripted walk of the toast vocabulary: every style, coalescing
/// bump, queue advance, bottom placement, and an action-bearing card, on a
/// fixed cadence. Shared by the gallery autorun, the Settings Developer row,
/// and the remote debug trigger, so all three demo entrypoints play the same
/// script. Wall-clock pacing is deliberate: this is demo choreography, not
/// synchronization.
@MainActor
public enum ToastDemo {
    private static var currentTask: Task<Void, Never>?

    /// Starts the demo after `delay`, cancelling any run already in flight.
    /// The optional delay exists so you can start it from Settings, navigate
    /// to any screen (e.g. a terminal), and watch the toasts play there.
    public static func run(on center: ToastCenter, after delay: Duration = .zero) {
        currentTask?.cancel()
        currentTask = Task {
            do {
                try await play(on: center, after: delay)
            } catch {
                // Cancelled by a newer run; the newer script owns the screen.
            }
        }
    }

    /// Cancels a scheduled or in-flight demo.
    public static func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    private static func play(on center: ToastCenter, after delay: Duration) async throws {
        let clock = ContinuousClock()
        func pause(_ seconds: Double) async throws {
            try await clock.sleep(for: .seconds(seconds))
        }

        try await clock.sleep(for: delay)
        center.present(.success("Workspace created"))
        try await pause(5.5)

        center.present(.failure(
            "Not connected to your Mac.",
            title: "Couldn't rename workspace",
            coalescingKey: "demo.error"
        ))
        try await pause(2)
        center.present(.failure(
            "Not connected to your Mac.",
            title: "Couldn't rename workspace",
            coalescingKey: "demo.error"
        ))
        try await pause(7.5)

        center.present(.success("First: workspace created"))
        center.present(.info("Second: agent finished"))
        center.present(.warning("Third: build is out of date"))
        try await pause(13)

        center.present(.info("Copied to clipboard", systemImage: "doc.on.doc"))
        try await pause(4.5)
        center.present(.success("Saved", placement: .bottom))
        try await pause(5)

        center.present(.failure(
            "The request timed out.",
            title: "Couldn't create workspace",
            action: Toast.Action(label: "Retry") {}
        ))
        try await pause(7.5)
        center.dismissAll()
    }
}
#endif
