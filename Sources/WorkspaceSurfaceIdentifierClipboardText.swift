import AppKit
import Foundation
import SwiftUI

enum WorkspaceSurfaceIdentifierClipboardText {
    @MainActor
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @MainActor
    static func copyWorkspaceIds(_ ids: [UUID], includeRefs: Bool) {
        copy(makeWorkspaceIds(ids, includeRefs: includeRefs))
    }

    @MainActor
    static func makeWorkspaceIds(_ ids: [UUID], includeRefs: Bool) -> String {
        let refs = includeRefs ? TerminalController.shared.v2WorkspaceRefs(for: ids) : [:]
        return make(workspaces: ids.map { (id: $0, ref: refs[$0]) })
    }

    static func makePane(paneId: UUID, paneRef: String? = nil) -> String {
        var lines: [String] = []
        if let paneRef {
            lines.append("pane_ref=\(paneRef)")
        }
        lines.append("pane_id=\(paneId.uuidString)")
        return lines.joined(separator: "\n")
    }

    static func makeSurface(surfaceId: UUID, surfaceRef: String? = nil) -> String {
        var lines: [String] = []
        if let surfaceRef {
            lines.append("surface_ref=\(surfaceRef)")
        }
        lines.append("surface_id=\(surfaceId.uuidString)")
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func makeWorkspacePaneSurfaceIdentifiers(
        workspaceId: UUID,
        paneId: UUID?,
        surfaceId: UUID,
        includeRefs: Bool = true
    ) -> String {
        let refs = includeRefs
            ? TerminalController.shared.v2WorkspacePaneAndSurfaceRefs(
                workspaceId: workspaceId,
                paneId: paneId,
                surfaceId: surfaceId
            )
            : nil
        return make(
            workspaceId: workspaceId,
            paneId: paneId,
            surfaceId: surfaceId,
            workspaceRef: refs?.workspaceRef,
            paneRef: refs?.paneRef,
            surfaceRef: refs?.surfaceRef
        )
    }

    static func make(workspaceId: UUID, workspaceRef: String? = nil) -> String {
        var lines: [String] = []
        if let workspaceRef {
            lines.append("workspace_ref=\(workspaceRef)")
        }
        lines.append("workspace_id=\(workspaceId.uuidString)")
        return lines.joined(separator: "\n")
    }

    static func make(workspaceIds: [UUID]) -> String {
        workspaceIds.map { make(workspaceId: $0) }.joined(separator: "\n\n")
    }

    static func make(workspaces: [(id: UUID, ref: String?)]) -> String {
        workspaces
            .map { make(workspaceId: $0.id, workspaceRef: $0.ref) }
            .joined(separator: "\n\n")
    }

    static func make(
        workspaceId: UUID,
        paneId: UUID? = nil,
        surfaceId: UUID,
        workspaceRef: String? = nil,
        paneRef: String? = nil,
        surfaceRef: String? = nil
    ) -> String {
        var lines: [String] = []
        if let workspaceRef {
            lines.append("workspace_ref=\(workspaceRef)")
        }
        lines.append("workspace_id=\(workspaceId.uuidString)")
        if let paneRef {
            lines.append("pane_ref=\(paneRef)")
        }
        if let paneId {
            lines.append("pane_id=\(paneId.uuidString)")
        }
        if let surfaceRef {
            lines.append("surface_ref=\(surfaceRef)")
        }
        lines.append("surface_id=\(surfaceId.uuidString)")
        return lines.joined(separator: "\n")
    }
}

enum LargeTextSelectionPolicy {
    enum Mode: Equatable {
        case liveSelection
        case copyOnly
    }

    static let defaultMaximumLiveSelectionLineFragments = 2_000
    static let defaultCharactersPerWrappedLine = 100

    static func mode(
        for text: String,
        charactersPerWrappedLine: Int = defaultCharactersPerWrappedLine,
        maximumLineFragments: Int = defaultMaximumLiveSelectionLineFragments
    ) -> Mode {
        guard charactersPerWrappedLine > 0, maximumLineFragments > 0 else {
            return .copyOnly
        }

        var lineFragments = 0
        var currentLineBytes = 0
        var sawAnyByte = false
        var previousByteWasNewline = false

        func appendLineFragment() -> Bool {
            currentLineBytes = 0
            lineFragments += 1
            return lineFragments <= maximumLineFragments
        }

        for byte in text.utf8 {
            sawAnyByte = true
            if byte == 10 {
                if currentLineBytes > 0 || previousByteWasNewline || lineFragments == 0 {
                    guard appendLineFragment() else { return .copyOnly }
                }
                previousByteWasNewline = true
            } else {
                previousByteWasNewline = false
                currentLineBytes += 1
                if currentLineBytes >= charactersPerWrappedLine {
                    guard appendLineFragment() else { return .copyOnly }
                }
            }
        }

        if currentLineBytes > 0 || !sawAnyByte || previousByteWasNewline {
            guard appendLineFragment() else { return .copyOnly }
        }
        return .liveSelection
    }
}

private struct BoundedTextSelectionModifier: ViewModifier {
    let text: String
    let charactersPerWrappedLine: Int
    let maximumLineFragments: Int

    func body(content: Content) -> some View {
        switch LargeTextSelectionPolicy.mode(
            for: text,
            charactersPerWrappedLine: charactersPerWrappedLine,
            maximumLineFragments: maximumLineFragments
        ) {
        case .liveSelection:
            content.textSelection(.enabled)
        case .copyOnly:
            content.contextMenu {
                Button {
                    WorkspaceSurfaceIdentifierClipboardText.copy(text)
                } label: {
                    Text(String(localized: "textSelection.copyText", defaultValue: "Copy Text"))
                }
            }
        }
    }
}

extension View {
    func boundedTextSelection(
        for text: String,
        charactersPerWrappedLine: Int = LargeTextSelectionPolicy.defaultCharactersPerWrappedLine,
        maximumLineFragments: Int = LargeTextSelectionPolicy.defaultMaximumLiveSelectionLineFragments
    ) -> some View {
        modifier(
            BoundedTextSelectionModifier(
                text: text,
                charactersPerWrappedLine: charactersPerWrappedLine,
                maximumLineFragments: maximumLineFragments
            )
        )
    }
}
