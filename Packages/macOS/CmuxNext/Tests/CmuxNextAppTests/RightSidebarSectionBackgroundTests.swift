import AppKit
@testable import CmuxNextApp
import Foundation
import Testing

/// The right sidebar's Files and Find lists paint no background of their own: a source list's
/// system gray under the list, with the window's ground under the header strip above it, read as
/// a band of another color across the top of the sidebar.
@MainActor @Suite(.serialized)
struct RightSidebarSectionBackgroundTests {
    @Test func theFilesTreePaintsNoBackground() {
        let view = FileExplorerSectionView(model: FileExplorerModel(), rootFolder: { URL(fileURLWithPath: "/tmp") }, perform: { _ in }, rowMenu: { _ in nil })
        #expect(view.table.backgroundColor.alphaComponent == 0)
    }

    @Test func theFindResultsPaintNoBackground() {
        let view = FindSectionView(model: FindSectionModel(search: { _, _ in nil }), rootFolder: { URL(fileURLWithPath: "/tmp") },
                                   effects: NullFileExplorerEffects())
        #expect(view.table.backgroundColor.alphaComponent == 0)
    }
}
