import Foundation
import Testing
@testable import CmuxHomeCore

/// Scratch diagnostic (pl-idle-wakeups testing, not for landing): why does the index inode move?
@Suite struct PLIdleDiagIndexRewriteTests {
    @Test func diagIndexBytesAcrossTwoWrites() async throws {
        let austin = ConversationID("conv_austin"), bob = ConversationID("conv_bob")
        let author = ParticipantID("agent_chief")
        func messages(_ c: ConversationID, _ n: Int) -> [Message] {
            (1...n).map { seq in
                Message(id: MessageID("\(c.rawValue)-m\(seq)"), conversation: c, seq: Seq(seq),
                        clientMessageID: IdempotencyKey("\(c.rawValue)-k\(seq)"), author: author,
                        parts: [.text("t\(seq)")], createdAt: Date(timeIntervalSince1970: Double(seq)))
            }
        }
        let cache = HomeCache(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("plidle-diag-\(UUID().uuidString)/home.json"))
        func inode(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.systemFileNumber] as? NSNumber)?.intValue ?? -1 }
        let writer = UUID()
        var state = HomeCacheState()
        state.windows = [austin: messages(austin, 50), bob: messages(bob, 50)]
        let e1 = try JSONEncoder().encode(state.index)
        let ok1 = await cache.write(state, sequence: 1, writer: writer)
        let d1 = try Data(contentsOf: cache.url), i1 = inode(cache.url)
        state.windows[bob] = messages(bob, 51)
        let e2 = try JSONEncoder().encode(state.index)
        let ok2 = await cache.write(state, sequence: 2, writer: writer)
        let d2 = try Data(contentsOf: cache.url), i2 = inode(cache.url)
        print("PLIDLE-DIAG ok1=\(ok1) ok2=\(ok2) inode1=\(i1) inode2=\(i2) encodeEqual=\(e1 == e2) diskEqual=\(d1 == d2) disk1==enc1=\(d1 == e1)")
        print("PLIDLE-DIAG e1=\(String(decoding: e1, as: UTF8.self))")
        print("PLIDLE-DIAG e2=\(String(decoding: e2, as: UTF8.self))")
        print("PLIDLE-DIAG d1=\(String(decoding: d1, as: UTF8.self))")
        let mtime1 = try FileManager.default.attributesOfItem(atPath: cache.url.path)[.modificationDate]
        print("PLIDLE-DIAG mtime=\(String(describing: mtime1))")
    }
}
