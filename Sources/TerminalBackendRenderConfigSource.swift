import Foundation
import GhosttyKit

/// One immutable, fully resolved Ghostty configuration generation.
struct TerminalBackendRenderConfigSnapshot: Equatable, Sendable {
    let revision: UInt64
    let data: Data
}

/// Process-scoped owner of finalized Ghostty configuration exported to renderer workers.
///
/// One notification observer and one router subscription serve every terminal. Visible
/// runtimes receive keyed callbacks; dormant runtimes retain their last immutable generation.
@MainActor
final class TerminalBackendRenderConfigSource {
    typealias Serializer = @MainActor () -> Data?

    private let serializer: Serializer
    private let notificationCenter: NotificationCenter
    private let notificationName: Notification.Name
    private var observer: NSObjectProtocol?
    private var revision: UInt64 = 0
    private var snapshotValue: TerminalBackendRenderConfigSnapshot?
    private var continuations: [
        UUID: AsyncStream<TerminalBackendRenderConfigSnapshot>.Continuation
    ] = [:]

    init(
        serializer: @escaping Serializer,
        notificationCenter: NotificationCenter = .default,
        notificationName: Notification.Name = .ghosttyConfigDidReload
    ) {
        self.serializer = serializer
        self.notificationCenter = notificationCenter
        self.notificationName = notificationName
        refresh(force: true)
        observer = notificationCenter.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh(force: false)
            }
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
        continuations.values.forEach { $0.finish() }
    }

    var current: TerminalBackendRenderConfigSnapshot? { snapshotValue }

#if DEBUG
    func debugActiveUpdateSubscriberCountForTesting() -> Int {
        continuations.count
    }
#endif

    func updates() -> AsyncStream<TerminalBackendRenderConfigSnapshot> {
        let identifier = UUID()
        let pair = AsyncStream<TerminalBackendRenderConfigSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[identifier] = pair.continuation
        if let snapshotValue {
            pair.continuation.yield(snapshotValue)
        }
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.continuations.removeValue(forKey: identifier)
            }
        }
        return pair.stream
    }

    /// Applies overrides in authority order: finalized app config, daemon defaults,
    /// then presentation-local values such as inherited font size.
    nonisolated static func layered(
        base: Data,
        backendDefaults: Data = Data(),
        presentationOverrides: Data = Data()
    ) -> Data {
        let layers = [base, backendDefaults, presentationOverrides].filter { !$0.isEmpty }
        guard !layers.isEmpty else { return Data() }
        var result = Data()
        for layer in layers {
            if !result.isEmpty, result.last != 0x0A {
                result.append(0x0A)
            }
            result.append(layer)
            if result.last != 0x0A {
                result.append(0x0A)
            }
        }
        return result
    }

    private func refresh(force: Bool) {
        guard let data = serializer(), !data.isEmpty else { return }
        if !force, snapshotValue?.data == data { return }
        revision &+= 1
        let snapshot = TerminalBackendRenderConfigSnapshot(
            revision: revision,
            data: data
        )
        snapshotValue = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}

extension GhosttyApp {
    /// Copies the complete finalized C configuration before releasing its export buffer.
    @MainActor
    func serializedTerminalRendererConfig() -> Data? {
        guard let config else { return nil }
        let exported = ghostty_config_serialize(config)
        defer { ghostty_string_free(exported) }
        guard let pointer = exported.ptr, exported.len > 0 else { return nil }
        return Data(bytes: pointer, count: Int(exported.len))
    }
}
