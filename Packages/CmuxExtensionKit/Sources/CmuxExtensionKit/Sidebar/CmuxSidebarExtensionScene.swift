import ExtensionFoundation
import ExtensionKit
import Foundation
import SwiftUI

/// Creates the ExtensionKit scene for a CMUX sidebar extension.
///
/// Most extension authors should conform their `@main` extension type to
/// `CmuxSidebarExtension` and use the protocol's default ExtensionKit
/// configuration instead of constructing this scene directly.
public struct CmuxSidebarExtensionScene<Extension: CmuxSidebarExtension>: AppExtensionScene {
    private let sidebarExtension: Extension
    private let id: String

    /// Creates an ExtensionKit scene for a CMUX sidebar extension.
    public init(_ extension: Extension, id: String = CMUXSidebarExtensionPoint.defaultSceneID) {
        self.sidebarExtension = `extension`
        self.id = id
    }

    @MainActor
    public var body: PrimitiveAppExtensionScene {
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
