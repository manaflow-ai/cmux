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
    var hasUnknownFields = false

    init(lines: [String]) {
        for line in lines {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
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
            } else {
                hasUnknownFields = true
            }
        }
    }
}
