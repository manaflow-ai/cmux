import CmuxSessionIndex

/// The load state of a transcript preview.
///
/// `loading` while the loader runs; `missingFile` when the transcript source is absent
/// or unreadable; `failed` on any other load error; `loaded` once the parsed turns have
/// been chunked into display rows.
enum SessionTranscriptPreviewState: Equatable {
    case loading
    case missingFile
    case failed
    case loaded([SessionTranscriptDisplayRow])
}
