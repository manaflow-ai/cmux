public import Foundation
import CmuxNextCompat

/// One earlier launch's metrics, reported as its own section under that launch's own profile, never merged
/// into the current launch's (a crashed 1.2 launch read by 1.3 stays a 1.2 section).
public struct MetricsLaunchSection<Contents: Sendable & Identifiable>: Sendable where Contents.ID == String {
    /// The source launch's file.
    public let file: URL
    /// The section's stable id: the source launch's identity from its file's header (``MetricsLaunchReading``),
    /// never the file name, which a later launch with a reused pid gets too. The upload sends it, so a section
    /// sent again after an upload whose delete did not happen (the app ended between the two) is counted once.
    public var id: String { contents.id }
    /// The source launch's profile and unsent samples.
    public let contents: Contents
}

/// The previous-launch fold: at launch, each earlier launch's metrics file becomes its own report section with
/// its own profile, and is deleted once that section's upload succeeded (p09-observability.md task 053).
///
/// Chrome's model: `FileMetricsProvider` with `SOURCE_HISTOGRAMS_ATOMIC_DIR` and
/// `ASSOCIATE_INTERNAL_PROFILE_OR_PREVIOUS_RUN` (components/metrics/file_metrics_provider.cc) reads each file
/// that `persistent_histograms.cc` left in the BrowserMetrics folder as an independent log with the system
/// profile embedded in that file, and deletes the file once it is reported.
///
/// Reading changes nothing, so ``sections()`` gives the same sections until an upload succeeds; a file is
/// deleted only by ``uploaded(_:)``, so a failed upload is retried at the next fold and a successful one is
/// never folded again. Every call reads or deletes files: call it off the main thread (BackgroundWork `.files`).
///
/// ```swift
/// let fold = MetricsLaunchFold(directory: folder, current: thisLaunchFile, reader: MetricsLaunchFileReader(role: .app))
/// let outcome = await fold.run { section in try await reports.send(section) }
/// ```
public struct MetricsLaunchFold<Reader: MetricsLaunchReading>: Sendable {
    /// The earlier launches, oldest name first, and the files that did not decode.
    public struct Scan: Sendable {
        /// One section per earlier launch whose file decoded.
        public var sections: [MetricsLaunchSection<Reader.Contents>]
        /// Launch files whose header or buckets did not decode.
        public var unreadable: [URL]
    }

    /// What one ``run(upload:)`` did.
    public struct Outcome<UploadError: Error>: Sendable {
        /// The ids of the sections uploaded and deleted.
        public var uploaded: [String] = []
        /// The sections whose upload failed; their files stay for the next fold.
        public var failed: [(id: String, error: UploadError)] = []
        /// Files that could not be listed, decoded or deleted.
        public var errors: [MetricsLaunchFoldError] = []
    }

    private let directory: URL
    private let currentName: String
    private let reader: Reader

    /// A fold of the launch files in `directory`, except `current` (this launch's own file in that folder, still
    /// being written).
    public init(directory: URL, current: URL, reader: Reader) {
        self.directory = directory
        currentName = current.lastPathComponent
        self.reader = reader
    }

    /// Each earlier launch's section, in file-name order. Reads only: a second call gives the same sections.
    public func sections() throws(MetricsLaunchFoldError) -> Scan {
        let files: [URL]
        do {
            files = try FileManager.checked.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles])
        } catch {
            throw MetricsLaunchFoldError.unlisted(directory)
        }
        var scan = Scan(sections: [], unreadable: [])
        let earlier = files.filter { $0.lastPathComponent != currentName && reader.isLaunchFile($0) }
        for file in earlier.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do throws(MetricsLaunchFoldError) {
                let contents = try reader.read(file)
                scan.sections.append(MetricsLaunchSection(file: file, contents: contents))
            } catch {
                scan.unreadable.append(file)
            }
        }
        return scan
    }

    /// The upload of `section` succeeded: its file is deleted, so it is never folded again.
    public func uploaded(_ section: MetricsLaunchSection<Reader.Contents>) throws(MetricsLaunchFoldError) {
        try delete(section.file)
    }

    /// Folds every earlier launch: uploads each section with `upload` and deletes the files whose upload
    /// succeeded. A file that does not decode is deleted without an upload (it would never decode later).
    public func run<UploadError: Error>(
        upload: (MetricsLaunchSection<Reader.Contents>) async throws(UploadError) -> Void
    ) async -> Outcome<UploadError> {
        var outcome = Outcome<UploadError>()
        let scan: Scan
        do throws(MetricsLaunchFoldError) { scan = try sections() } catch {
            outcome.errors.append(error)
            return outcome
        }
        for file in scan.unreadable {
            outcome.errors.append(.unreadable(file))
            do throws(MetricsLaunchFoldError) { try delete(file) } catch { outcome.errors.append(error) }
        }
        for section in scan.sections {
            do throws(UploadError) {
                try await upload(section)
            } catch {
                outcome.failed.append((id: section.id, error: error))
                continue
            }
            do throws(MetricsLaunchFoldError) {
                try uploaded(section)
                outcome.uploaded.append(section.id)
            } catch {
                outcome.errors.append(error)
            }
        }
        return outcome
    }

    private func delete(_ file: URL) throws(MetricsLaunchFoldError) {
        do { try FileManager.checked.removeItem(at: file) } catch { throw MetricsLaunchFoldError.undeleted(file) }
    }
}
