/// Where one attached file is on its way to the backend.
public enum AttachmentState: Hashable, Sendable {
    /// Bytes are on their way; `received` counts what the backend has.
    case uploading(received: UInt64)
    /// Every byte arrived and matched its checksum.
    case uploaded
    /// The upload stopped and did not resume in time. Retrying resumes it.
    case failed
    /// The bytes are gone (removed by the backend, or the original was
    /// deleted on the device). The file has to be attached again.
    case missing
}
