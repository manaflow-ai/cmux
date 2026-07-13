struct GitDiffNameStatusToken {
    let path: String
    let oldPath: String?
    let status: GitDiffStatus

    init?(token: String?, tokens: [String?], index: inout Int) {
        guard let token else { return nil }
        let pieces = token.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let statusRaw = pieces[0]
        guard let first = statusRaw.first else { return nil }
        switch first {
        case "A":
            status = .added
        case "M", "T", "U":
            status = .modified
        case "D":
            status = .deleted
        case "R":
            status = .renamed
        default:
            return nil
        }
        if status == .renamed {
            if pieces.count >= 3 {
                oldPath = pieces[1]
                path = pieces[2]
                index += 1
            } else {
                guard index + 2 < tokens.count,
                      let decodedOldPath = tokens[index + 1],
                      let decodedPath = tokens[index + 2] else { return nil }
                oldPath = decodedOldPath
                path = decodedPath
                index += 3
            }
        } else if pieces.count >= 2 {
            oldPath = nil
            path = pieces[1]
            index += 1
        } else {
            guard index + 1 < tokens.count,
                  let decodedPath = tokens[index + 1] else { return nil }
            oldPath = nil
            path = decodedPath
            index += 2
        }
    }
}
