import CmuxNextAgentActivity
import Foundation
import Testing

/// A lane's project tag is the last part of its session's folder, read from the string. The folder
/// is often another machine's (`/home/...` on a Linux peer), and on macOS anything that asks the
/// disk about a `/home` path goes through the automounter: 7 ms blocked per row, measured
/// (cmux#46416). A file URL made for the name did that once per session row, on the queue that
/// reads the session feed.
struct AgentLaneProjectNameTests {
    private static func summary(_ id: String, cwd: String) -> [String: Any] {
        ["sessionId": id, "name": id, "cwd": cwd, "lane": ["state": "idle", "since": 1_760_000_000_000.0]]
    }

    @Test func theProjectIsTheFoldersLastPart() {
        let names: [(String, String?)] = [
            ("/home/leo/Projects/cmux", "cmux"),
            ("/home/leo/Projects/cmux/", "cmux"),
            ("/Users/someone/work/my app", "my app"),
            ("relative/folder", "folder"),
            ("/", nil),
            ("", nil),
        ]
        for (cwd, project) in names {
            #expect(AgentActivityLane.of(summary: Self.summary("s", cwd: cwd))?.project == project, "cwd \(cwd)")
        }
    }

    /// 500 rows of another machine's folders. Read from the string this takes a few milliseconds;
    /// with one automounter lookup per row it took 3.5 s on a Mac (`/home` is an autofs map there).
    @Test func aPeersFolderIsNeverLookedUpOnThisDisk() {
        let rows = (0..<500).map { Self.summary("s\($0)", cwd: "/home/peer-\($0 % 7)/Projects/repo-\($0)") }
        let clock = ContinuousClock()
        var named = 0
        let elapsed = clock.measure {
            for row in rows where AgentActivityLane.of(summary: row)?.project != nil { named += 1 }
        }
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print("lane-parse: 500 rows with /home folders in \(String(format: "%.1f", ms)) ms")
        #expect(named == 500)
        #expect(elapsed < .milliseconds(500), "500 lane rows took \(ms) ms: something looks each folder up on disk")
    }
}
