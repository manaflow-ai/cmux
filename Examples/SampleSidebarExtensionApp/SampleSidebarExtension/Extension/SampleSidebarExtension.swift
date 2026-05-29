import ExtensionFoundation
import ExtensionKit
import SwiftUI
import CmuxExtensionKit

@main
final class SampleSidebarExtension: AppExtension {
    required init() {}

    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier("com.manaflow.cmux.sidebar")
    }

    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(self.body)
    }

    var body: some AppExtensionScene {
        PrimitiveAppExtensionScene(id: "sidebar") {
            SampleSidebarView(model: SidebarConnectionModel.shared)
        } onConnection: { connection in
            SidebarConnectionModel.shared.accept(connection: connection)
        }
    }
}
