import CmuxAgentChat
import Foundation
import Testing

#if canImport(UIKit)
import UIKit
#endif

@testable import CmuxAgentChatUI

@Suite("Artifact presentation boundaries")
struct ChatArtifactPresentationBoundaryTests {
    @Test("rapid completed transitions preserve one unique selected path")
    func rapidPageTransitions() {
        let allPaths = ["/notes.md", "/data.csv", "/build.log"]
        var state = ChatArtifactPageControllerState(
            paths: allPaths,
            selectedPath: allPaths[0]
        )

        for index in 0..<60 {
            let next = allPaths[index.isMultiple(of: 2) ? 1 : 0]
            let didComplete = state.completeTransition(to: next)
            #expect(didComplete)
            state.update(paths: allPaths + [allPaths[1]], selectedPath: next)
            #expect(state.paths == allPaths)
            #expect(state.selectedPath == next)
        }

        #expect(state.path(before: "/data.csv") == "/notes.md")
        #expect(state.path(after: "/data.csv") == "/build.log")
        let didCompleteUnknown = state.completeTransition(to: "/unknown")
        #expect(!didCompleteUnknown)
    }

    @Test("completed selection reports an expanded neighbor topology exactly once")
    func pageTopologyReload() {
        let notes = "/notes.md"
        let data = "/data.csv"
        let log = "/build.log"
        var state = ChatArtifactPageControllerState(
            paths: [notes, data],
            selectedPath: notes
        )

        let didComplete = state.completeTransition(to: data)
        #expect(didComplete)
        let didExpandPaths = state.update(paths: [notes, data, log], selectedPath: data)
        #expect(didExpandPaths)
        #expect(state.path(after: data) == log)
        let didChangeDeduplicatedPaths = state.update(
            paths: [notes, data, log, data],
            selectedPath: data
        )
        #expect(!didChangeDeduplicatedPaths)
    }

    @Test("large skipped-highlight updates need no full TextKit snapshot")
    func textUpdatePlanning() {
        let streaming = ChatArtifactTextUpdatePlan(
            reachedEOF: false,
            highlightDecision: .skippedForSize,
            searchQuery: ""
        )
        let finished = ChatArtifactTextUpdatePlan(
            reachedEOF: true,
            highlightDecision: .skippedForSize,
            searchQuery: ""
        )
        let searched = ChatArtifactTextUpdatePlan(
            reachedEOF: false,
            highlightDecision: .skippedForSize,
            searchQuery: "error"
        )

        #expect(!streaming.requiresFullTextSnapshot)
        #expect(!finished.requiresFullTextSnapshot)
        #expect(searched.requiresFullTextSnapshot)
    }

    @Test("accessibility projection remains a single bounded excerpt")
    func boundedAccessibilityContent() {
        var content = ChatArtifactTextAccessibilityContent()
        content.append(String(repeating: "x", count: 100_000))
        content.append("tail")

        #expect(content.excerpt.count == ChatArtifactTextAccessibilityContent.maximumCharacterCount)
        #expect(content.isTruncated)
        #expect(!content.excerpt.contains("tail"))
    }

    #if canImport(UIKit)
    @Test("large text remains interactive behind one bounded accessibility element")
    @MainActor
    func textContainerInteractionAndAccessibility() {
        let container = ChatArtifactTextContainerView()

        #expect(container.isUserInteractionEnabled)
        #expect(container.textView.isUserInteractionEnabled)
        #expect(container.textView.isScrollEnabled)
        #expect(container.isAccessibilityElement)
        #expect(!container.textView.isAccessibilityElement)
        #expect(container.textView.accessibilityElementsHidden)
    }
    #endif

    @Test("child routes retain the live loader and exact descendant path")
    func folderChildLoaderRouting() async throws {
        let expected = ChatArtifactDirectoryListing(entries: [])
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            supportsDirectoryBrowsing: true,
            scope: .terminal(workspaceID: "workspace", surfaceID: "surface"),
            list: { path in
                #expect(path == "/project/docs")
                return expected
            }
        )
        let route = ChatArtifactFolderRoute(
            parentPath: "/project",
            childName: "docs",
            scope: .terminal,
            loader: loader
        )

        #expect(route.path == "/project/docs")
        #expect(route.loader.scope == loader.scope)
        #expect(try await route.loader.list(path: route.path) == expected)
    }
}
