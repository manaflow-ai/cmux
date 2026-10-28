import Foundation
@testable import CmuxWorkspaces

struct SessionSnapshotChannelImportFixture: SessionSnapshotRepresenting {
    var version: Int
    var windows: [String]
    var hasWindows: Bool { !windows.isEmpty }
}
