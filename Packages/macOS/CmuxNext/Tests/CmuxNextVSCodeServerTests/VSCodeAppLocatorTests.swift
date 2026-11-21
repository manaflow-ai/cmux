import CmuxNextVSCodeServer
import Foundation
import Testing

/// Open Folder in VS Code (Inline) is offered only with VS Code installed; the lookup that decides it
/// is the one the run takes.
struct VSCodeAppLocatorTests {
    @Test func theBundleIDWinsThenTheInstallPlacesThenInsiders() {
        let stable = URL(fileURLWithPath: "/Volumes/x/Visual Studio Code.app")
        let insiders = URL(fileURLWithPath: "/Volumes/x/Insiders.app")
        let byID = VSCodeAppLocator(homeDirectory: "/Users/a", fileExists: { _ in true }) { $0 == "com.microsoft.VSCode" ? stable : insiders }
        #expect(byID.installed() == stable)
        let inHome = VSCodeAppLocator(homeDirectory: "/Users/a", fileExists: { $0 == "/Users/a/Applications/Visual Studio Code.app" }) {
            $0 == "com.microsoft.VSCodeInsiders" ? insiders : nil
        }
        #expect(inHome.installed()?.path == "/Users/a/Applications/Visual Studio Code.app")
        let onlyInsiders = VSCodeAppLocator(homeDirectory: "/Users/a", fileExists: { _ in false }) {
            $0 == "com.microsoft.VSCodeInsiders" ? insiders : nil
        }
        #expect(onlyInsiders.installed() == insiders)
    }

    @Test func noneInstalledIsNil() {
        #expect(VSCodeAppLocator(homeDirectory: "/Users/a", fileExists: { _ in false }) { _ in nil }.installed() == nil)
    }
}
