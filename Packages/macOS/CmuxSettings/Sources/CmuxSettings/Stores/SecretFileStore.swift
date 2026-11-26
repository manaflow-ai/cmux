public import Foundation

/// Typed read/write/observe access to secret strings, each stored in its own
/// `0600` file under a base directory.
///
/// The store is an `actor`; reads, writes, and reset are `async`. It is the
/// secret-handling sibling of ``JSONConfigStore`` and
/// ``UserDefaultsSettingsStore``, and only accepts ``SecretFileKey``. Unlike
/// ``JSONConfigStore`` it never serializes the value into the shared
/// `cmux.json`: each secret is written to its own file with owner-only
/// permissions, so the secret never appears in a config users edit, copy,
/// version, or template.
///
/// Files resolve to `<baseDirectory>/<key.fileName>`. The app constructs the
/// store with `~/.config/cmux` (the same directory as `cmux.json`); tests pass
/// a temporary directory.
///
/// ```swift
/// let store = SecretFileStore(baseDirectory: configDirectory)
/// try await store.set("hunter2", for: catalog.automation.socketPassword)
/// for await secret in store.values(for: catalog.automation.socketPassword) {
///     // react to the secret changing
/// }
/// ```
public actor SecretFileStore {
    /// Posted (in process) after any secret file is written or cleared.
    ///
    /// `userInfo[SecretFileStore.changedKeyIDKey]` carries the affected key's
    /// ``SecretFileKey/id``. ``values(for:)`` listens for this and re-reads.
    public static let didChangeNotification = Notification.Name("cmux.secretFileStoreDidChange")

    /// `userInfo` key under which ``didChangeNotification`` carries the changed key id.
    public static let changedKeyIDKey = "keyID"

    /// The directory secret files are resolved under.
    public nonisolated let baseDirectory: URL

    /// Creates a store rooted at `baseDirectory`.
    /// - Parameter baseDirectory: The directory holding the secret files
    ///   (created on first write if absent). The app uses `~/.config/cmux`.
    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// The current secret for `key`, or its ``SecretFileKey/defaultValue`` when absent/empty.
    /// - Throws: If the file exists but cannot be read.
    public func value(for key: SecretFileKey) throws -> String {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return key.defaultValue
        }
        let data = try Data(contentsOf: url)
        guard let raw = String(data: data, encoding: .utf8) else {
            return key.defaultValue
        }
        let normalized = Self.normalized(raw)
        return normalized ?? key.defaultValue
    }

    /// Whether a non-empty secret is stored on disk for `key`.
    ///
    /// This inspects the stored file directly and ignores
    /// ``SecretFileKey/defaultValue``, so a key with a non-empty default does not
    /// make an absent secret look present.
    public func hasValue(for key: SecretFileKey) -> Bool {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else {
            return false
        }
        return Self.normalized(raw) != nil
    }

    /// Writes `value` to the key's `0600` file, or clears it when empty after
    /// newline-trimming, then posts ``didChangeNotification``.
    /// - Throws: If the directory cannot be created or the write fails.
    public func set(_ value: String, for key: SecretFileKey) throws {
        let normalized = value.trimmingCharacters(in: .newlines)
        if normalized.isEmpty {
            try reset(key)
            return
        }
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = fileURL(for: key)
        try Data(normalized.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        postChange(for: key)
    }

    /// Deletes the key's secret file (if present), then posts ``didChangeNotification``.
    /// - Throws: If the file exists but cannot be removed.
    public func reset(_ key: SecretFileKey) throws {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
        postChange(for: key)
    }

    /// An `AsyncStream` yielding the current secret and every later change.
    ///
    /// The first element is the current value; subsequent elements arrive when
    /// ``didChangeNotification`` fires for this key. Buffering is
    /// `.bufferingNewest(1)`. Cancelling the consuming `Task` removes the
    /// observer token, cancels the bounded drain task, and ends the stream.
    public nonisolated func values(for key: SecretFileKey) -> AsyncStream<String> {
        AsyncStream<String>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let (signals, signalContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )

            let observer = NotificationObserverToken(
                NotificationCenter.default.addObserver(
                    forName: SecretFileStore.didChangeNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] note in
                    if let changedID = note.userInfo?[SecretFileStore.changedKeyIDKey] as? String,
                       changedID != key.id {
                        return
                    }
                    guard self != nil else { return }
                    signalContinuation.yield(())
                }
            )

            let drainTask = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                var lastYielded = (try? await self.value(for: key)) ?? key.defaultValue
                continuation.yield(lastYielded)

                for await _ in signals {
                    if Task.isCancelled { break }
                    let current = (try? await self.value(for: key)) ?? key.defaultValue
                    if current != lastYielded {
                        lastYielded = current
                        continuation.yield(current)
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                drainTask.cancel()
                signalContinuation.finish()
                observer.remove()
            }
        }
    }

    /// The on-disk URL backing `key`.
    public nonisolated func fileURL(for key: SecretFileKey) -> URL {
        baseDirectory.appendingPathComponent(key.fileName, isDirectory: false)
    }

    private func postChange(for key: SecretFileKey) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: [Self.changedKeyIDKey: key.id]
        )
    }

    private static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
