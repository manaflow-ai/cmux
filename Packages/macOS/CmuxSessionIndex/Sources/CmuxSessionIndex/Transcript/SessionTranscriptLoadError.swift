/// Errors surfaced while loading a session transcript for preview.
///
/// `missingFile` means the transcript source could not be read (absent file, empty
/// preview, or unsupported layout); `databaseError` carries a human-readable failure
/// message for transcript backends that fail mid-read.
public enum SessionTranscriptLoadError: Error {
    case missingFile
    case databaseError(String)
}
