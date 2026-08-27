import Foundation
import Testing
@testable import CmuxSwiftRenderUI

/// Containment behavior at the publish layer: when a source's evaluation is
/// rejected (here, by tripping the node budget), the model must keep the last
/// good render instead of flashing empty or publishing a truncated tree.
@Suite("Custom sidebar last-good publish")
@MainActor
struct CustomSidebarLastGoodTests {
    private func makeSidebarFile(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-lastgood-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("demo.swift", isDirectory: false)
        try source.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    @Test func budgetTrippedSourceKeepsThePreviousRender() async throws {
        let fileURL = try makeSidebarFile("""
        VStack {
            Text("good")
        }
        """)
        let model = CustomSidebarModel(fileURL: fileURL)
        model.reload()
        await model.renderSwift(dataContext: [:])
        #expect(model.swiftRender?.children.first?.text == "good")

        // Author saves a pathological edit: 100k rows trips the node budget,
        // the render comes back nil, and the previous output must stay up.
        try """
        VStack {
            ForEach(0..<100_000) { i in
                Text("Row \\(i)")
            }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        model.reload()
        await model.renderSwift(dataContext: [:])
        #expect(model.swiftRender?.children.first?.text == "good")
        #expect(model.hasRenderedSwift)
    }
}
