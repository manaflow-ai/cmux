import ExtensionFoundation
import ExtensionKit
import Foundation
import SwiftUI

struct CmuxSidebarExtensionScene<Extension: CmuxSidebarExtension>: AppExtensionScene {
    private let sidebarExtension: Extension
    private let id: String

    init(_ extension: Extension, id: String = CmuxSidebarExtensionPoint.defaultSceneID) {
        self.sidebarExtension = `extension`
        self.id = id
    }

    @MainActor
    var body: PrimitiveAppExtensionScene {
        let runtime = CmuxSidebarExtensionRuntime(sidebarExtension: sidebarExtension)
        let runtimeBox: AnySidebarRuntimeBox = SidebarRuntimeBox(runtime)
        return PrimitiveAppExtensionScene(id: id) {
            sidebarExtension.body
        } onConnection: { connection in
            runtimeBox.accept(connection)
        }
    }
}

private final class SidebarRuntimeBox<Extension: CmuxSidebarExtension>: AnySidebarRuntimeBox, @unchecked Sendable {
    private let runtime: CmuxSidebarExtensionRuntime<Extension>

    init(_ runtime: CmuxSidebarExtensionRuntime<Extension>) {
        self.runtime = runtime
    }

    override func accept(_ connection: NSXPCConnection) -> Bool {
        runtime.accept(connection)
    }
}

private class AnySidebarRuntimeBox: @unchecked Sendable {
    func accept(_ connection: NSXPCConnection) -> Bool {
        false
    }
}
