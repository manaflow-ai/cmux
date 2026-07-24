struct WorktreePorcelainRecord {
    var path: String?
    var headOID: String?
    var branchReference: String?
    var isDetached = false
    var isBare = false
    var isLocked = false
    var lockReason: String?
    var isPrunable = false
    var prunableReason: String?
    /// Whether the record cannot be trusted: a quoted path failed to decode,
    /// or a legacy line-delimited record contained a line that may be the
    /// continuation of an unescaped path rather than an attribute.
    var isRejected = false

    /// Parses one porcelain record.
    ///
    /// NUL-delimited fields are unambiguous, so unrecognized attributes from
    /// newer Git versions are ignored for forward compatibility. Legacy
    /// line-delimited output cannot distinguish a future attribute from the
    /// continuation of a path containing a newline, and only frozen-vocabulary
    /// legacy Gits produce it, so any unknown line rejects the whole record.
    ///
    /// - Parameters:
    ///   - lines: The record's attribute fields.
    ///   - legacyLineMode: Whether the fields came from line-delimited output,
    ///     which C-quotes unusual paths and requires strict unknown handling.
    init(lines: [String], legacyLineMode: Bool = false) {
        let pathDecoder = GitCStylePathDecoder()
        for line in lines {
            if line.hasPrefix("worktree ") {
                let rawPath = String(line.dropFirst("worktree ".count))
                if legacyLineMode {
                    guard let decodedPath = pathDecoder.decodeIfQuoted(rawPath) else {
                        isRejected = true
                        continue
                    }
                    path = decodedPath
                } else {
                    path = rawPath
                }
            } else if line.hasPrefix("HEAD ") {
                headOID = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                branchReference = String(line.dropFirst("branch ".count))
            } else if line == "detached" {
                isDetached = true
            } else if line == "bare" {
                isBare = true
            } else if line == "locked" {
                isLocked = true
            } else if line.hasPrefix("locked ") {
                isLocked = true
                lockReason = String(line.dropFirst("locked ".count))
            } else if line == "prunable" {
                isPrunable = true
            } else if line.hasPrefix("prunable ") {
                isPrunable = true
                prunableReason = String(line.dropFirst("prunable ".count))
            } else if legacyLineMode {
                isRejected = true
            }
        }
    }
}
