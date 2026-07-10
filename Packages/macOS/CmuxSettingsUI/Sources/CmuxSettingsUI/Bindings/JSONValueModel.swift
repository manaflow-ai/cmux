import CmuxSettings
import Foundation
import Observation

/// `@Observable` view-model that projects one ``JSONKey`` value into
/// SwiftUI-bindable state.
///
/// Same shape as ``DefaultsValueModel`` but bound to a ``JSONConfigStore``.
/// Set / reset failures populate the model's ``lastWriteError`` *and* are
/// pushed into the optional injected ``SettingsErrorLog`` so the UI can
/// surface them centrally; the model never silently swallows a failure.
///
/// Lifecycle: the observation is owned by a ``SettingReadDriver`` held by the
/// model; the driver's `deinit` cancels the iterating task when the model
/// deallocates, finishing the change stream and tearing down its underlying
/// observation. A bare `weak self` is **not** enough — the parked task never
/// re-checks `self` for an idle key (see
/// https://github.com/manaflow-ai/cmux/issues/5302).
@MainActor
@Observable
public final class JSONValueModel<Value: SettingCodable> {
    /// The most recently observed value. Updated by the JSON store's file
    /// watcher.
    public private(set) var current: Value

    /// Monotonic identity for each value delivered by the change stream.
    /// Consumers can use this to reject observations captured before a write.
    public private(set) var observationRevision: UInt64 = 0

    /// Whether the JSON change stream has yielded at least once.
    public private(set) var hasObservedValue = false

    /// Error from the most recent set/reset attempt, or `nil`.
    public private(set) var lastWriteError: Error?
    /// Monotonic identifier of the most recently completed set/reset attempt.
    public private(set) var lastCompletedWriteID: UInt64 = 0
    private(set) var writeResultRevision = 0

    private let store: JSONConfigStore
    private let key: JSONKey<Value>
    private let errorLog: SettingsErrorLog
    @ObservationIgnored private let makeStream: () -> AsyncStream<Value>
    @ObservationIgnored private var nextWriteID: UInt64 = 0
    @ObservationIgnored private var writeTask: Task<Void, Never>?

    /// Owns the change-stream subscription and cancels it when this model
    /// deallocates.
    @ObservationIgnored private let observation = SettingReadDriver<Value>()

    /// Creates a model bound to ``key`` in ``store``.
    ///
    /// - Parameters:
    ///   - store: The JSON config store to read from and write to.
    ///   - key: The setting to observe.
    ///   - errorLog: Global log that write failures are pushed into so
    ///     they surface centrally. The runtime always provides one; see
    ///     ``SettingsRuntime/errorLog``.
    public convenience init(
        store: JSONConfigStore,
        key: JSONKey<Value>,
        errorLog: SettingsErrorLog
    ) {
        self.init(
            store: store,
            key: key,
            errorLog: errorLog,
            makeStream: { store.values(for: key) }
        )
    }

    /// Designated initializer with an injectable change-stream factory.
    ///
    /// The `makeStream` seam lets tests drive the observation with a stream
    /// whose teardown they can observe. Production code uses the public
    /// `init(store:key:errorLog:)`, which wires `makeStream` to the store.
    ///
    /// - Parameters:
    ///   - store: The JSON config store used for writes (`set`/`reset`).
    ///   - key: The setting to observe.
    ///   - errorLog: Global log that write failures are pushed into.
    ///   - makeStream: Builds the change stream this model iterates.
    init(
        store: JSONConfigStore,
        key: JSONKey<Value>,
        errorLog: SettingsErrorLog,
        makeStream: @escaping () -> AsyncStream<Value>
    ) {
        self.store = store
        self.key = key
        self.errorLog = errorLog
        self.makeStream = makeStream
        self.current = key.defaultValue
    }

    /// Starts the JSON change stream for the retained model.
    ///
    /// Idempotent: the first call starts observation and later calls are
    /// ignored by ``SettingReadDriver``. Views should call this from a mounted
    /// lifecycle hook such as `.task`, not from their initializer.
    public func startObserving() {
        observation.activate(makeStream) { [weak self] value in
            guard let self else { return }
            self.observationRevision &+= 1
            self.current = value
            self.hasObservedValue = true
        }
    }

    /// Persists the value. The observation stream is the single writer of
    /// ``current``, which updates once the write lands and the store
    /// yields it back. On failure ``lastWriteError`` is populated and
    /// recorded in the error log. Synchronous because SwiftUI `Binding`
    /// setters can't `await`.
    @discardableResult
    public func set(_ value: Value) -> UInt64 {
        let keyID = key.id
        let requestID = makeWriteRequestID()
        let previousWriteTask = writeTask
        writeTask = Task { [weak self, store, key] in
            await previousWriteTask?.value
            do {
                try await store.set(value, for: key)
                await MainActor.run {
                    guard let self else { return }
                    self.finishWrite(requestID: requestID, error: nil)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.finishWrite(requestID: requestID, error: error)
                    self.errorLog.record(error, keyID: keyID)
                }
            }
        }
        return requestID
    }

    /// Removes the JSON entry (parents that become empty are pruned).
    /// ``current`` updates when the stream observes the reset.
    @discardableResult
    public func reset() -> UInt64 {
        let keyID = key.id
        let requestID = makeWriteRequestID()
        let previousWriteTask = writeTask
        writeTask = Task { [weak self, store, key] in
            await previousWriteTask?.value
            do {
                try await store.reset(key)
                await MainActor.run {
                    guard let self else { return }
                    self.finishWrite(requestID: requestID, error: nil)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.finishWrite(requestID: requestID, error: error)
                    self.errorLog.record(error, keyID: keyID)
                }
            }
        }
        return requestID
    }

    private func makeWriteRequestID() -> UInt64 {
        nextWriteID &+= 1
        return nextWriteID
    }

    private func finishWrite(requestID: UInt64, error: Error?) {
        lastCompletedWriteID = requestID
        lastWriteError = error
        writeResultRevision &+= 1
        if requestID == nextWriteID {
            writeTask = nil
        }
    }
}
