import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeSessionTransferControlCommandContext: ControlCommandContext {
    var importResolution: ControlSessionImportResolution = .restored(
        sourcePath: "/tmp/in.json",
        windowCount: 1,
        heldBackResumeCount: 0,
        droppedRemoteWorkspaceCount: 0
    )
    var exportResolution: ControlSessionExportResolution = .exported(path: "/tmp/out.json", sourcePath: "/tmp/src.json")
    private(set) var importSources: [ControlSessionImportSource] = []
    private(set) var exportRequests: [(path: String, overwrite: Bool)] = []

    func controlSessionImport(source: ControlSessionImportSource) -> ControlSessionImportResolution {
        importSources.append(source)
        return importResolution
    }

    func controlSessionExport(path: String, overwrite: Bool) -> ControlSessionExportResolution {
        exportRequests.append((path, overwrite))
        return exportResolution
    }
}
