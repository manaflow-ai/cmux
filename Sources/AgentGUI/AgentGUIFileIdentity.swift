import CmuxAgentTruthKit
import Darwin
import Foundation

struct AgentGUIFileIdentity: Sendable {
    let path: String
    let inodeLikeToken: String
    let size: Int
    let firstLine: String?

    func journalIdentity(baselineFirstLine: String?, forceHeadTruncated: Bool = false) -> JournalIdentity {
        JournalIdentity(
            path: path,
            inodeLikeToken: inodeLikeToken,
            headTruncated: forceHeadTruncated || (baselineFirstLine != nil && firstLine != baselineFirstLine)
        )
    }

    static func capture(path: String) -> Result<AgentGUIFileIdentity, POSIXError> {
        var info = stat()
        guard stat(path, &info) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            return .failure(POSIXError(code))
        }
        return .success(AgentGUIFileIdentity(
            path: path,
            inodeLikeToken: "\(info.st_dev):\(info.st_ino)",
            size: Int(info.st_size),
            firstLine: readFirstLine(path: path)
        ))
    }

    private static func readFirstLine(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        guard !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
    }
}
