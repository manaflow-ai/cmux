#if DEBUG
public import AppKit
internal import CMUXDebugLog

/// Encodes a window's content view to a sequenced PNG snapshot on disk for the
/// terminal cmd-click UI-test scenario.
///
/// This is a byte-faithful lift of the app-target
/// `TerminalCmdClickUITestRecorder`'s `captureWindowSnapshotIfRequested` /
/// `safeScreenshotLabel` helpers. The recorder constructs one writer with the
/// scenario's configured screenshot directory (`nil`/empty when the scenario
/// did not request captures) and drives ``capture(label:window:sequence:)`` from
/// the `capture_window` command. The per-scenario snapshot counter stays owned
/// app-side and is passed `inout`, so it advances by one only when a file is
/// actually written, matching the legacy increment ordering exactly.
public struct UITestWindowSnapshotWriter {
    private let directory: String?

    /// Creates a writer that writes PNG snapshots into `directory`.
    ///
    /// - Parameter directory: The screenshot output directory, or `nil`/empty
    ///   when the scenario did not request window captures (in which case
    ///   ``capture(label:window:sequence:)`` returns `nil` without writing).
    public init(directory: String?) {
        self.directory = directory
    }

    /// Captures `window`'s content view as a PNG into the configured directory,
    /// named `<sequence>-<sanitized label>.png`, returning the written file path
    /// or `nil` when capture is unavailable (no directory, no content view,
    /// empty bounds, encoding failure, or a filesystem error).
    ///
    /// - Parameters:
    ///   - label: The capture label; sanitized to a filename-safe component.
    ///   - window: The window whose `contentView` is cached to a bitmap.
    ///   - sequence: The app-owned snapshot counter, advanced by one only when a
    ///     file is written.
    @MainActor
    public func capture(label: String, window: NSWindow, sequence: inout Int) -> String? {
        guard let directory,
              !directory.isEmpty,
              let contentView = window.contentView else {
            return nil
        }
        let bounds = contentView.bounds
        guard !bounds.isEmpty,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        contentView.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        do {
            let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let sequenceComponent = String(format: "%03d", sequence)
            sequence += 1
            let fileURL = directoryURL
                .appendingPathComponent("\(sequenceComponent)-\(Self.sanitizedLabel(label)).png")
            try data.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            logDebugEvent("cmdclick.ui.snapshot failed label=\(label) error=\(error.localizedDescription)")
            return nil
        }
    }

    /// Sanitizes `label` to a filename-safe component (alphanumerics plus
    /// `-_.`), replacing every other scalar with `-`, trimming leading/trailing
    /// separators, and falling back to `"capture"` when the result is empty.
    static func sanitizedLabel(_ label: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = label.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let cleaned = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return cleaned.isEmpty ? "capture" : cleaned
    }
}
#endif
