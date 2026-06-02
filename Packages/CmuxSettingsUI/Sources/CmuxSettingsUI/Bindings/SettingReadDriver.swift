import SwiftUI

/// Pushes values from a settings store's change `AsyncStream` into a SwiftUI
/// `@State` (via its `Binding`), so a property wrapper's reads ride on `@State`
/// invalidation instead of Observation.
///
/// This is the mechanism behind ``LiveSetting``. Holding the latest value in
/// the consuming view's own `@State` is what makes updates reliable inside an
/// AppKit `NSHostingView` host, where an `@Observable` model updated off the
/// render cycle does not re-invalidate the view; `@State` is SwiftUI's most
/// fundamental, host-agnostic invalidation primitive. The driver is
/// store-agnostic — it only needs an `AsyncStream<Value>` — so the same path
/// works for every key kind (UserDefaults, JSON, secret).
@MainActor
final class SettingReadDriver<Value: Sendable> {
    private var task: Task<Void, Never>?

    /// Starts forwarding `makeStream()`'s elements into `sink`. Idempotent:
    /// the first call wins and later calls (every `update()`) are no-ops, so
    /// the subscription is created once for the lifetime of the `@State`.
    ///
    /// - Parameters:
    ///   - makeStream: Builds the store change stream. Called at most once.
    ///   - sink: The `@State`-backed binding to write each value into.
    func activate(_ makeStream: () -> AsyncStream<Value>, sink: Binding<Value>) {
        guard task == nil else { return }
        let stream = makeStream()
        task = Task { @MainActor in
            for await value in stream {
                if Task.isCancelled { break }
                sink.wrappedValue = value
            }
        }
    }

    deinit { task?.cancel() }
}
