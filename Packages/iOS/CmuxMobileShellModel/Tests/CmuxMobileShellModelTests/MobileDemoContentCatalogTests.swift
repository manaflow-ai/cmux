import Foundation
import Testing

@testable import CmuxMobileShellModel

/// The demonstration catalog must be internally consistent (every terminal is
/// backed by a script, every notification targets a real demo workspace) and
/// review-safe: no internal build-lane vocabulary anywhere in the sample
/// content, and no identifier that could collide with a real Mac.
@Suite struct MobileDemoContentCatalogTests {
    private let catalog = MobileDemoContentCatalog.standard(
        now: Date(timeIntervalSince1970: 1_756_500_000)
    )

    @Test func workspacesAreStampedWithTheDemoComputer() {
        #expect(!catalog.workspaces.isEmpty)
        #expect(catalog.workspaces.allSatisfy {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        })
        #expect(catalog.workspaces.allSatisfy { !$0.terminals.isEmpty })
        // At least one row exercises the unread indicator path.
        #expect(catalog.workspaces.contains { $0.hasUnread && ($0.unreadCount ?? 0) > 0 })
        // Agent task rows: every workspace carries a todo surface with items.
        #expect(catalog.workspaces.allSatisfy { workspace in
            workspace.surfaces.contains { $0.kind == .todo && !($0.todo?.items.isEmpty ?? true) }
        })
        // Statuses vary so the status lane demonstrates more than one state.
        let statuses = Set(catalog.workspaces.compactMap { workspace in
            workspace.surfaces.first { $0.kind == .todo }?.todo?.status
        })
        #expect(statuses.count >= 2)
    }

    @Test func everyTerminalHasAScriptAndEveryScriptATerminal() {
        let terminalIDs = Set(
            catalog.workspaces.flatMap(\.terminals).map(\.id.rawValue)
        )
        let scriptIDs = Set(catalog.terminalScripts.map(\.surfaceID))
        #expect(terminalIDs == scriptIDs)
        #expect(catalog.terminalScripts.allSatisfy { !$0.transcript.isEmpty })
        #expect(catalog.terminalScripts.allSatisfy { !$0.displayDirectory.isEmpty })
        // Every session gets a navigable fake project tree so cd/ls/pwd/cat
        // have something coherent to compose over.
        #expect(catalog.terminalScripts.allSatisfy { !$0.fileSystem.entries.isEmpty })
        #expect(catalog.terminalScripts.allSatisfy { script in
            script.fileSystem.entries.contains {
                if case .directory = $0 { return true }
                return false
            }
        })
    }

    @Test func notificationsTargetDemoWorkspacesNewestFirst() {
        #expect(!catalog.notifications.isEmpty)
        let workspaceIDs = Set(catalog.workspaces.map(\.id.rawValue))
        let surfaceIDs = Set(catalog.workspaces.flatMap(\.terminals).map(\.id.rawValue))
        for notification in catalog.notifications {
            #expect(notification.macDeviceID == MobileDemoContentCatalog.macDeviceID)
            #expect(workspaceIDs.contains(notification.remoteWorkspaceID))
            if let surfaceID = notification.remoteSurfaceID {
                #expect(surfaceIDs.contains(surfaceID))
            }
        }
        let createdAts = catalog.notifications.map(\.createdAt)
        #expect(createdAts == createdAts.sorted(by: >))
        // Both unread and read entries so the feed shows live badge state.
        #expect(catalog.notifications.contains { !$0.isRead })
        #expect(catalog.notifications.contains { $0.isRead })
    }

    @Test func identifiersArePrefixedAgainstRealMacCollisions() {
        #expect(MobileDemoContentCatalog.macDeviceID.hasPrefix("cmux-demo-"))
        #expect(catalog.workspaces.allSatisfy { $0.id.rawValue.hasPrefix("cmux-demo-") })
        #expect(
            catalog.workspaces.flatMap(\.terminals).allSatisfy {
                $0.id.rawValue.hasPrefix("cmux-demo-")
            }
        )
        #expect(catalog.notifications.allSatisfy {
            $0.notificationID.hasPrefix("cmux-demo-")
        })
    }

    @Test func sampleContentAvoidsInternalLaneVocabulary() {
        // Guideline 2.2 sensitivity: the public app's demonstration content
        // must not name internal distribution lanes or pre-release programs.
        let forbidden = ["beta", "testflight", "nightly", "internal build"]
        var corpus: [String] = []
        for workspace in catalog.workspaces {
            corpus.append(workspace.name)
            corpus.append(workspace.previewText ?? "")
            corpus.append(workspace.currentDirectory ?? "")
            for terminal in workspace.terminals {
                corpus.append(terminal.name)
            }
            for surface in workspace.surfaces {
                corpus.append(surface.title)
                for item in surface.todo?.items ?? [] {
                    corpus.append(item.text)
                }
            }
        }
        for notification in catalog.notifications {
            corpus.append(notification.title)
            corpus.append(notification.body)
            corpus.append(notification.workspaceTitle ?? "")
            corpus.append(notification.surfaceTitle ?? "")
        }
        func appendTree(_ directory: MobileDemoDirectory) {
            for entry in directory.entries {
                switch entry {
                case let .directory(name, nested):
                    corpus.append(name)
                    appendTree(nested)
                case let .file(name, contents):
                    corpus.append(name)
                    corpus.append(contents ?? "")
                }
            }
        }
        for script in catalog.terminalScripts {
            corpus.append(script.transcript)
            corpus.append(script.workingDirectory)
            corpus.append(script.displayDirectory)
            appendTree(script.fileSystem)
        }
        for text in corpus {
            let lowered = text.lowercased()
            for word in forbidden {
                #expect(!lowered.contains(word), "found forbidden vocabulary '\(word)' in: \(text)")
            }
        }
    }
}
