import CMUXMobileCore
import CmuxMobilePairedMac
@testable import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import SwiftUI
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceMacSelectionTests {
    @Test func pickerIncludesPairedMacWithNoWorkspace() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        let view = workspaceListView(
            workspaces: [workspace(id: "ws-a", macDeviceID: "mac-a")],
            store: store
        )

        #expect(view.liveMachineSnapshots.macPickerMachines.map(\.id) == ["mac-a", "mac-b"])
    }

    @Test func titlePickerMachineSelectionSwitchesBeforeApplyingFilter() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20, isActive: true),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        var selected = WorkspaceMacSelection.all
        var requestedSwitches: [String] = []
        let view = workspaceListView(
            workspaces: [workspace(id: "ws-a", macDeviceID: "mac-a")],
            store: store,
            macSelection: Binding(
                get: { selected },
                set: { selected = $0 }
            ),
            switchMac: { macDeviceID in
                requestedSwitches.append(macDeviceID)
                return true
            }
        )

        await view.applyMacTitlePickerSelection(.machine("mac-b"))

        #expect(requestedSwitches == ["mac-b"])
        #expect(selected == .machine("mac-b"))
    }

    @Test func titlePickerWorkspaceOnlyMachineSelectionAppliesLocalFilterWithoutSwitch() async throws {
        let manualID = "manual-127.0.0.1:50922"
        let store = await shellStore(pairedMacs: [])
        var selected = WorkspaceMacSelection.all
        var requestedSwitches: [String] = []
        let view = workspaceListView(
            workspaces: [workspace(id: "ws-manual", macDeviceID: manualID)],
            store: store,
            macSelection: Binding(
                get: { selected },
                set: { selected = $0 }
            ),
            switchMac: { macDeviceID in
                requestedSwitches.append(macDeviceID)
                return false
            }
        )

        let pendingSwitchTask = view.handleMacTitlePickerSelection(.machine(manualID))
        let startedSwitchTask: Bool
        if case .some = pendingSwitchTask {
            startedSwitchTask = true
        } else {
            startedSwitchTask = false
        }

        #expect(!startedSwitchTask)
        #expect(requestedSwitches.isEmpty)
        #expect(selected == .machine(manualID))
    }

    @Test func staleTitlePickerMachineSelectionDoesNotSwitch() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20, isActive: true),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        var selected = WorkspaceMacSelection.all
        var requestedSwitches: [String] = []
        let view = workspaceListView(
            workspaces: [workspace(id: "ws-a", macDeviceID: "mac-a")],
            store: store,
            macSelection: Binding(
                get: { selected },
                set: { selected = $0 }
            ),
            switchMac: { macDeviceID in
                requestedSwitches.append(macDeviceID)
                return true
            }
        )

        await view.applyMacTitlePickerSelection(.machine("mac-b"), switchGeneration: 1)

        #expect(requestedSwitches.isEmpty)
        #expect(selected == .all)
    }

    @Test(.disabled("title-picker switch tests fail or deadlock in CI (rotted while this target was unwired); fix and re-enable, see PR 7659")) func cancelingPendingTitlePickerSwitchCancelsUnderlyingSwitch() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20, isActive: true),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        var selected = WorkspaceMacSelection.all
        var requestedSwitches: [String] = []
        var cancelRestoreRequests: [Bool] = []
        var cancelDidStart = false
        var cancelStartedContinuation: CheckedContinuation<Void, Never>?
        var switchContinuation: CheckedContinuation<Bool, Never>?
        var switchDidStart = false
        var switchStartedContinuation: CheckedContinuation<Void, Never>?
        func markSwitchStarted() {
            guard !switchDidStart else { return }
            switchDidStart = true
            switchStartedContinuation?.resume()
            switchStartedContinuation = nil
        }
        func waitForSwitchStart() async {
            guard !switchDidStart else { return }
            await withCheckedContinuation { continuation in
                if switchDidStart {
                    continuation.resume()
                } else {
                    switchStartedContinuation = continuation
                }
            }
        }
        func markCancelStarted() {
            guard !cancelDidStart else { return }
            cancelDidStart = true
            cancelStartedContinuation?.resume()
            cancelStartedContinuation = nil
        }
        func waitForCancelStart() async {
            guard !cancelDidStart else { return }
            await withCheckedContinuation { continuation in
                if cancelDidStart {
                    continuation.resume()
                } else {
                    cancelStartedContinuation = continuation
                }
            }
        }
        let view = workspaceListView(
            workspaces: [workspace(id: "ws-a", macDeviceID: "mac-a")],
            store: store,
            macSelection: Binding(
                get: { selected },
                set: { selected = $0 }
            ),
            switchMac: { macDeviceID in
                requestedSwitches.append(macDeviceID)
                markSwitchStarted()
                return await withCheckedContinuation { continuation in
                    switchContinuation = continuation
                }
            },
            cancelMacSwitch: { restorePreviousOnCancel in
                cancelRestoreRequests.append(restorePreviousOnCancel)
                markCancelStarted()
            }
        )

        let pendingSwitchTask = view.handleMacTitlePickerSelection(.machine("mac-b"))
        await waitForSwitchStart()

        view.handleMacTitlePickerSelection(.all)
        await waitForCancelStart()
        #expect(requestedSwitches == ["mac-b"])
        #expect(cancelRestoreRequests == [true])
        #expect(selected == .all)

        switchContinuation?.resume(returning: true)
        await pendingSwitchTask?.value

        #expect(selected == .all)
    }

    @Test(.disabled("title-picker switch tests fail or deadlock in CI (rotted while this target was unwired); fix and re-enable, see PR 7659")) func pendingTitlePickerMachineSelectionLetsAllMacsCancelSwitch() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20, isActive: true),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        var selected = WorkspaceMacSelection.all
        var requestedSwitches: [String] = []
        var cancelRestoreRequests: [Bool] = []
        var cancelDidStart = false
        var cancelStartedContinuation: CheckedContinuation<Void, Never>?
        var switchContinuation: CheckedContinuation<Bool, Never>?
        var switchDidStart = false
        var switchStartedContinuation: CheckedContinuation<Void, Never>?
        func markSwitchStarted() {
            guard !switchDidStart else { return }
            switchDidStart = true
            switchStartedContinuation?.resume()
            switchStartedContinuation = nil
        }
        func waitForSwitchStart() async {
            guard !switchDidStart else { return }
            await withCheckedContinuation { continuation in
                if switchDidStart {
                    continuation.resume()
                } else {
                    switchStartedContinuation = continuation
                }
            }
        }
        func markCancelStarted() {
            guard !cancelDidStart else { return }
            cancelDidStart = true
            cancelStartedContinuation?.resume()
            cancelStartedContinuation = nil
        }
        func waitForCancelStart() async {
            guard !cancelDidStart else { return }
            await withCheckedContinuation { continuation in
                if cancelDidStart {
                    continuation.resume()
                } else {
                    cancelStartedContinuation = continuation
                }
            }
        }
        let view = workspaceListView(
            workspaces: [workspace(id: "ws-a", macDeviceID: "mac-a")],
            store: store,
            macSelection: Binding(
                get: { selected },
                set: { selected = $0 }
            ),
            switchMac: { macDeviceID in
                requestedSwitches.append(macDeviceID)
                markSwitchStarted()
                return await withCheckedContinuation { continuation in
                    switchContinuation = continuation
                }
            },
            cancelMacSwitch: { restorePreviousOnCancel in
                cancelRestoreRequests.append(restorePreviousOnCancel)
                markCancelStarted()
            }
        )

        let pendingSwitchTask = view.handleMacTitlePickerSelection(.machine("mac-b"))
        await waitForSwitchStart()

        #expect(view.macTitlePickerSelection.wrappedValue == .machine("mac-b"))
        view.macTitlePickerSelection.wrappedValue = .all
        await waitForCancelStart()

        #expect(requestedSwitches == ["mac-b"])
        #expect(cancelRestoreRequests == [true])
        #expect(selected == .all)

        switchContinuation?.resume(returning: true)
        await pendingSwitchTask?.value

        #expect(selected == .all)
    }

    @Test(.disabled("title-picker switch tests fail or deadlock in CI (rotted while this target was unwired); fix and re-enable, see PR 7659")) func titlePickerWaitsForAllMacsCancelBeforeStartingNextMachineSwitch() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 30, isActive: true),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 20),
            pairedMac(id: "mac-c", name: "Mac C", lastSeenAt: 10),
        ])
        var selected = WorkspaceMacSelection.all
        var requestedSwitches: [String] = []
        var firstSwitchContinuation: CheckedContinuation<Bool, Never>?
        var cancelContinuation: CheckedContinuation<Void, Never>?
        var switchDidStart = false
        var switchStartedContinuation: CheckedContinuation<Void, Never>?
        var cancelDidStart = false
        var cancelStartedContinuation: CheckedContinuation<Void, Never>?
        func markSwitchStarted() {
            guard !switchDidStart else { return }
            switchDidStart = true
            switchStartedContinuation?.resume()
            switchStartedContinuation = nil
        }
        func waitForSwitchStart() async {
            guard !switchDidStart else { return }
            await withCheckedContinuation { continuation in
                if switchDidStart {
                    continuation.resume()
                } else {
                    switchStartedContinuation = continuation
                }
            }
        }
        func markCancelStarted() {
            guard !cancelDidStart else { return }
            cancelDidStart = true
            cancelStartedContinuation?.resume()
            cancelStartedContinuation = nil
        }
        func waitForCancelStart() async {
            guard !cancelDidStart else { return }
            await withCheckedContinuation { continuation in
                if cancelDidStart {
                    continuation.resume()
                } else {
                    cancelStartedContinuation = continuation
                }
            }
        }
        let view = workspaceListView(
            workspaces: [workspace(id: "ws-a", macDeviceID: "mac-a")],
            store: store,
            macSelection: Binding(
                get: { selected },
                set: { selected = $0 }
            ),
            switchMac: { macDeviceID in
                requestedSwitches.append(macDeviceID)
                if macDeviceID == "mac-b" {
                    markSwitchStarted()
                    return await withCheckedContinuation { continuation in
                        firstSwitchContinuation = continuation
                    }
                }
                return true
            },
            cancelMacSwitch: { _ in
                markCancelStarted()
                await withCheckedContinuation { continuation in
                    cancelContinuation = continuation
                }
            }
        )

        let firstTask = view.handleMacTitlePickerSelection(.machine("mac-b"))
        await waitForSwitchStart()

        view.handleMacTitlePickerSelection(.all)
        await waitForCancelStart()

        let secondTask = view.handleMacTitlePickerSelection(.machine("mac-c"))

        #expect(requestedSwitches == ["mac-b"])
        #expect(selected == .all)

        cancelContinuation?.resume()
        await secondTask?.value

        #expect(requestedSwitches == ["mac-b", "mac-c"])
        #expect(selected == .machine("mac-c"))

        firstSwitchContinuation?.resume(returning: false)
        await firstTask?.value
    }

    @Test(.disabled("title-picker switch tests fail or deadlock in CI (rotted while this target was unwired); fix and re-enable, see PR 7659")) func replacingPendingTitlePickerMachineSelectionKeepsRollbackArmed() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 30, isActive: true),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 20),
            pairedMac(id: "mac-c", name: "Mac C", lastSeenAt: 10),
        ])
        var selected = WorkspaceMacSelection.all
        var requestedSwitches: [String] = []
        var cancelRestoreRequests: [Bool] = []
        var firstSwitchContinuation: CheckedContinuation<Bool, Never>?
        var secondSwitchContinuation: CheckedContinuation<Bool, Never>?
        var firstSwitchDidStart = false
        var firstSwitchStartedContinuation: CheckedContinuation<Void, Never>?
        var cancelDidStart = false
        var cancelStartedContinuation: CheckedContinuation<Void, Never>?
        func markFirstSwitchStarted() {
            guard !firstSwitchDidStart else { return }
            firstSwitchDidStart = true
            firstSwitchStartedContinuation?.resume()
            firstSwitchStartedContinuation = nil
        }
        func waitForFirstSwitchStart() async {
            guard !firstSwitchDidStart else { return }
            await withCheckedContinuation { continuation in
                if firstSwitchDidStart {
                    continuation.resume()
                } else {
                    firstSwitchStartedContinuation = continuation
                }
            }
        }
        func markCancelStarted() {
            guard !cancelDidStart else { return }
            cancelDidStart = true
            cancelStartedContinuation?.resume()
            cancelStartedContinuation = nil
        }
        func waitForCancelStart() async {
            guard !cancelDidStart else { return }
            await withCheckedContinuation { continuation in
                if cancelDidStart {
                    continuation.resume()
                } else {
                    cancelStartedContinuation = continuation
                }
            }
        }
        let view = workspaceListView(
            workspaces: [workspace(id: "ws-a", macDeviceID: "mac-a")],
            store: store,
            macSelection: Binding(
                get: { selected },
                set: { selected = $0 }
            ),
            switchMac: { macDeviceID in
                requestedSwitches.append(macDeviceID)
                if macDeviceID == "mac-b" {
                    markFirstSwitchStarted()
                    return await withCheckedContinuation { continuation in
                        firstSwitchContinuation = continuation
                    }
                }
                return await withCheckedContinuation { continuation in
                    secondSwitchContinuation = continuation
                }
            },
            cancelMacSwitch: { restorePreviousOnCancel in
                cancelRestoreRequests.append(restorePreviousOnCancel)
                markCancelStarted()
            }
        )

        let firstTask = view.handleMacTitlePickerSelection(.machine("mac-b"))
        await waitForFirstSwitchStart()

        let secondTask = view.handleMacTitlePickerSelection(.machine("mac-c"))
        await Task.yield()

        #expect(!cancelRestoreRequests.contains(false))

        view.handleMacTitlePickerSelection(.all)
        await waitForCancelStart()

        #expect(cancelRestoreRequests == [true])
        #expect(selected == .all)

        firstSwitchContinuation?.resume(returning: false)
        secondSwitchContinuation?.resume(returning: false)
        await firstTask?.value
        await secondTask?.value

        #expect(selected == .all)
    }

    @Test(.disabled("title-picker switch tests fail or deadlock in CI (rotted while this target was unwired); fix and re-enable, see PR 7659")) func selectingWorkspaceCancelsPendingTitlePickerSwitch() async throws {
        let workspaceID = MobileWorkspacePreview.ID(rawValue: "ws-a")
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20, isActive: true),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        var selected = WorkspaceMacSelection.all
        var selectedWorkspaces: [MobileWorkspacePreview.ID] = []
        var requestedSwitches: [String] = []
        var cancelRestoreRequests: [Bool] = []
        var switchContinuation: CheckedContinuation<Bool, Never>?
        var switchDidStart = false
        var switchStartedContinuation: CheckedContinuation<Void, Never>?
        func markSwitchStarted() {
            guard !switchDidStart else { return }
            switchDidStart = true
            switchStartedContinuation?.resume()
            switchStartedContinuation = nil
        }
        func waitForSwitchStart() async {
            guard !switchDidStart else { return }
            await withCheckedContinuation { continuation in
                if switchDidStart {
                    continuation.resume()
                } else {
                    switchStartedContinuation = continuation
                }
            }
        }
        let view = workspaceListView(
            workspaces: [workspace(id: workspaceID.rawValue, macDeviceID: "mac-a")],
            store: store,
            selectWorkspace: { selectedWorkspaces.append($0) },
            macSelection: Binding(
                get: { selected },
                set: { selected = $0 }
            ),
            switchMac: { macDeviceID in
                requestedSwitches.append(macDeviceID)
                markSwitchStarted()
                return await withCheckedContinuation { continuation in
                    switchContinuation = continuation
                }
            },
            cancelMacSwitch: { restorePreviousOnCancel in
                cancelRestoreRequests.append(restorePreviousOnCancel)
            }
        )

        let pendingSwitchTask = view.handleMacTitlePickerSelection(.machine("mac-b"))
        await waitForSwitchStart()

        let selectionTask = view.selectWorkspaceFromList(workspaceID)
        await selectionTask?.value

        #expect(requestedSwitches == ["mac-b"])
        #expect(cancelRestoreRequests == [true])
        #expect(selectedWorkspaces == [workspaceID])

        switchContinuation?.resume(returning: true)
        await pendingSwitchTask?.value

        #expect(selected == .all)
    }

    @Test(.disabled("title-picker switch tests fail or deadlock in CI (rotted while this target was unwired); fix and re-enable, see PR 7659")) func newerWorkspaceSelectionInvalidatesDeferredRowSelection() async throws {
        let firstWorkspaceID = MobileWorkspacePreview.ID(rawValue: "ws-a")
        let secondWorkspaceID = MobileWorkspacePreview.ID(rawValue: "ws-b")
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20, isActive: true),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        var selected = WorkspaceMacSelection.all
        var selectedWorkspaces: [MobileWorkspacePreview.ID] = []
        var switchContinuation: CheckedContinuation<Bool, Never>?
        var switchDidStart = false
        var switchStartedContinuation: CheckedContinuation<Void, Never>?
        var cancelContinuation: CheckedContinuation<Void, Never>?
        var cancelDidStart = false
        var cancelStartedContinuation: CheckedContinuation<Void, Never>?
        func markSwitchStarted() {
            guard !switchDidStart else { return }
            switchDidStart = true
            switchStartedContinuation?.resume()
            switchStartedContinuation = nil
        }
        func waitForSwitchStart() async {
            guard !switchDidStart else { return }
            await withCheckedContinuation { continuation in
                if switchDidStart {
                    continuation.resume()
                } else {
                    switchStartedContinuation = continuation
                }
            }
        }
        func markCancelStarted() {
            guard !cancelDidStart else { return }
            cancelDidStart = true
            cancelStartedContinuation?.resume()
            cancelStartedContinuation = nil
        }
        func waitForCancelStart() async {
            guard !cancelDidStart else { return }
            await withCheckedContinuation { continuation in
                if cancelDidStart {
                    continuation.resume()
                } else {
                    cancelStartedContinuation = continuation
                }
            }
        }
        let view = workspaceListView(
            workspaces: [
                workspace(id: firstWorkspaceID.rawValue, macDeviceID: "mac-a"),
                workspace(id: secondWorkspaceID.rawValue, macDeviceID: "mac-a"),
            ],
            store: store,
            selectWorkspace: { selectedWorkspaces.append($0) },
            macSelection: Binding(
                get: { selected },
                set: { selected = $0 }
            ),
            switchMac: { _ in
                markSwitchStarted()
                return await withCheckedContinuation { continuation in
                    switchContinuation = continuation
                }
            },
            cancelMacSwitch: { _ in
                markCancelStarted()
                await withCheckedContinuation { continuation in
                    cancelContinuation = continuation
                }
            }
        )

        let pendingSwitchTask = view.handleMacTitlePickerSelection(.machine("mac-b"))
        await waitForSwitchStart()

        let firstSelectionTask = view.selectWorkspaceFromList(firstWorkspaceID)
        await waitForCancelStart()
        let secondSelectionTask = view.selectWorkspaceFromList(secondWorkspaceID)

        cancelContinuation?.resume()
        await firstSelectionTask?.value
        await secondSelectionTask?.value

        #expect(selectedWorkspaces == [secondWorkspaceID])

        switchContinuation?.resume(returning: true)
        await pendingSwitchTask?.value
    }

    @Test func selectingCoalescedPairedMacMatchesAliasWorkspaceRows() async throws {
        let route = try route(host: "100.82.214.112")
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-old", name: "Desk Mac", route: route, lastSeenAt: 10),
            pairedMac(id: "mac-fresh", name: "Desk Mac", route: route, lastSeenAt: 20, isActive: true),
        ])
        #expect(store.displayPairedMacs.map(\.macDeviceID) == ["mac-fresh"])

        let aliasWorkspace = workspace(id: "ws-old", macDeviceID: "mac-old")
        var view = workspaceListView(workspaces: [aliasWorkspace], store: store)
        view.macSelection = .machine("mac-fresh")

        #expect(view.activeFilter.matches(aliasWorkspace))
    }

    @Test func pickerUsesCoalescedCustomNameForRepresentativeMachine() async throws {
        let route = try route(host: "100.82.214.112")
        let store = await shellStore(pairedMacs: [
            pairedMac(
                id: "mac-old",
                name: "Desk Mac",
                route: route,
                lastSeenAt: 10,
                customName: "Desk setup"
            ),
            pairedMac(id: "mac-fresh", name: "Desk Mac", route: route, lastSeenAt: 20, isActive: true),
        ])

        let view = workspaceListView(workspaces: [], store: store)

        #expect(view.liveMachineSnapshots.macPickerMachines.map(\.name) == ["Desk setup"])
    }

    @Test func createWorkspaceIsGatedWhenSpecificSelectedMacIsNotForeground() async throws {
        let store = await shellStore(
            pairedMacs: [
                pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20, isActive: true),
                pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
            ],
            connectionState: .connected
        )
        var view = workspaceListView(workspaces: [], store: store)

        view.macSelection = .machine("mac-b")
        #expect(!view.canCreateWorkspaceForMacSelection)

        view.macSelection = .machine("mac-a")
        #expect(view.canCreateWorkspaceForMacSelection)

        view.macSelection = .all
        #expect(view.canCreateWorkspaceForMacSelection)
    }

    @Test func sharedSelectionScopeAllowsCreateWhenConnectedMacIsAlias() {
        let scope = WorkspaceMacSelectionScope(
            selection: .machine("mac-fresh"),
            workspaces: [],
            displayPairedMacs: [
                pairedMac(id: "mac-fresh", name: "Desk Mac", lastSeenAt: 20),
            ],
            foregroundMacDeviceID: "mac-old",
            aliasesFor: { id in
                id == "mac-fresh" ? ["mac-fresh", "mac-old"] : [id]
            }
        )

        #expect(scope.visibleSelection == .machine("mac-fresh"))
        #expect(scope.canCreateWorkspace(base: true))
    }

    @Test func sharedSelectionScopeDisablesCreateWhileMacSwitchPending() {
        let scope = WorkspaceMacSelectionScope(
            selection: .all,
            workspaces: [workspace(id: "ws-a", macDeviceID: "mac-a")],
            displayPairedMacs: [
                pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
                pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
            ],
            foregroundMacDeviceID: "mac-a",
            aliasesFor: { [$0] }
        )

        #expect(!scope.canCreateWorkspace(base: true, switchPending: true))
    }

    @Test func sharedSelectionScopeAllowsCreateWhenManualForegroundMacIsSelected() {
        let manualID = "manual-127.0.0.1:50922"
        let scope = WorkspaceMacSelectionScope(
            selection: .machine(manualID),
            workspaces: [workspace(id: "ws-manual", macDeviceID: manualID)],
            displayPairedMacs: [],
            foregroundMacDeviceID: manualID,
            aliasesFor: { [$0] }
        )

        #expect(scope.visibleSelection == .machine(manualID))
        #expect(scope.canCreateWorkspace(base: true))
    }

    @Test func allMacSelectionPreservesFilterMenuMachineScope() {
        let scope = WorkspaceMacSelectionScope(
            selection: .all,
            workspaces: [
                workspace(id: "ws-a", macDeviceID: "mac-a"),
                workspace(id: "ws-b", macDeviceID: "mac-b"),
            ],
            displayPairedMacs: [],
            foregroundMacDeviceID: nil,
            aliasesFor: { [$0] }
        )
        let active = scope.activeFilter(base: MobileWorkspaceListFilter(machines: ["mac-b"]))

        #expect(active.machines == ["mac-b"])
    }

    @Test func allMacFilterMenuMachineScopeMatchesAliasWorkspaceRows() throws {
        let route = try route(host: "100.82.214.112")
        let aliasWorkspace = workspace(id: "ws-old", macDeviceID: "mac-old")
        let scope = WorkspaceMacSelectionScope(
            selection: .all,
            workspaces: [aliasWorkspace],
            displayPairedMacs: [
                pairedMac(id: "mac-fresh", name: "Desk Mac", route: route, lastSeenAt: 20),
            ],
            foregroundMacDeviceID: nil,
            aliasesFor: { id in
                id == "mac-fresh" ? ["mac-fresh", "mac-old"] : [id]
            }
        )

        let active = scope.activeFilter(base: MobileWorkspaceListFilter(machines: ["mac-fresh"]))

        #expect(active.matches(aliasWorkspace))
    }

    @Test func filterMenuMachinesUseRepresentativeIDsForAliasWorkspaces() async throws {
        let route = try route(host: "100.82.214.112")
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-old", name: "Desk Mac", route: route, lastSeenAt: 10),
            pairedMac(id: "mac-fresh", name: "Desk Mac", route: route, lastSeenAt: 20, isActive: true),
            pairedMac(id: "mac-b", name: "Air", lastSeenAt: 15),
        ])
        let view = workspaceListView(
            workspaces: [
                workspace(id: "ws-old", macDeviceID: "mac-old"),
                workspace(id: "ws-b", macDeviceID: "mac-b"),
            ],
            store: store
        )

        let machines = view.filterMenuMachines(
            machineSnapshots: view.liveMachineSnapshots,
            visibleSelection: view.visibleMacSelection
        )

        #expect(Set(machines.map(\.id)) == ["mac-b", "mac-fresh"])
        #expect(!machines.map(\.id).contains("mac-old"))
        #expect(view.filterMenuPresentMachineIDs == ["mac-fresh", "mac-b"])
    }

    @Test func filterMenuMachinesHideWhenMacPickerOwnsMachineScope() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        var view = workspaceListView(
            workspaces: [
                workspace(id: "ws-a", macDeviceID: "mac-a"),
                workspace(id: "ws-b", macDeviceID: "mac-b"),
            ],
            store: store
        )
        view.macSelection = .machine("mac-a")

        let machines = view.filterMenuMachines(
            machineSnapshots: view.liveMachineSnapshots,
            visibleSelection: view.visibleMacSelection
        )

        #expect(machines.isEmpty)
    }

    @Test func filterMenuMachinesShowWhenAllMacsCanUseMachineScope() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        let view = workspaceListView(
            workspaces: [
                workspace(id: "ws-a", macDeviceID: "mac-a"),
                workspace(id: "ws-b", macDeviceID: "mac-b"),
            ],
            store: store
        )

        let machines = view.filterMenuMachines(
            machineSnapshots: view.liveMachineSnapshots,
            visibleSelection: view.visibleMacSelection
        )

        #expect(machines.map(\.id) == ["mac-a", "mac-b"])
    }

    @Test func filterMenuPruningClearsMachineSelectionWhenMacPickerOwnsMachineScope() {
        var filter = MobileWorkspaceListFilter(machines: ["mac-b"])
        let changed = filter.pruneMachinesForFilterMenu(visibleMacSelection: .machine("mac-a"))

        #expect(changed)
        #expect(filter.machines.isEmpty)
    }

    @Test func filterMenuPruningKeepsMachineSelectionWhenAllMacsCanUseMachineScope() {
        var filter = MobileWorkspaceListFilter(machines: ["mac-b"])
        let changed = filter.pruneMachinesForFilterMenu(visibleMacSelection: .all)

        #expect(!changed)
        #expect(filter.machines == ["mac-b"])
    }

    @Test func filterMenuPruningClearsSelectionWhenMachineSectionWouldHide() {
        var filter = MobileWorkspaceListFilter(machines: ["mac-a"])
        let changed = filter.pruneMachinesForFilterMenu(presentMachineIDs: ["mac-a"])

        #expect(changed)
        #expect(filter.machines.isEmpty)
    }

    @Test func filterMenuPruningClearsSelectionWhenOnlyDuplicateMachineIDsArePresent() {
        var filter = MobileWorkspaceListFilter(machines: ["mac-a"])
        let changed = filter.pruneMachinesForFilterMenu(presentMachineIDs: ["mac-a", "mac-a"])

        #expect(changed)
        #expect(filter.machines.isEmpty)
    }

    @Test func filterMenuPruningKeepsVisibleMachineSelection() {
        var filter = MobileWorkspaceListFilter(machines: ["mac-a"])
        let changed = filter.pruneMachinesForFilterMenu(presentMachineIDs: ["mac-a", "mac-b"])

        #expect(!changed)
        #expect(filter.machines == ["mac-a"])
    }

    private func workspaceListView(
        workspaces: [MobileWorkspacePreview],
        store: CMUXMobileShellStore,
        selectWorkspace: @escaping (MobileWorkspacePreview.ID) -> Void = { _ in },
        macSelection: Binding<WorkspaceMacSelection>? = nil,
        switchMac: (@MainActor (String) async -> Bool)? = nil,
        cancelMacSwitch: (@MainActor (Bool) async -> Void)? = nil
    ) -> WorkspaceListView {
        WorkspaceListView(
            workspaces: workspaces,
            selectedWorkspaceID: nil,
            host: "Test Mac",
            connectionStatus: .unavailable,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            selectWorkspace: selectWorkspace,
            createWorkspace: {},
            macSelection: macSelection ?? binding(initialValue: .all),
            switchMac: switchMac,
            cancelMacSwitch: cancelMacSwitch,
            store: store
        )
    }

    private func binding(initialValue: WorkspaceMacSelection) -> Binding<WorkspaceMacSelection> {
        var value = initialValue
        return Binding(
            get: { value },
            set: { value = $0 }
        )
    }

    private func shellStore(
        pairedMacs: [MobilePairedMac],
        connectionState: MobileConnectionState = .disconnected
    ) async -> CMUXMobileShellStore {
        let suiteName = "WorkspaceMacSelectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: connectionState,
            pairedMacStore: WorkspaceMacSelectionPairedMacStore(pairedMacs),
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            identityProvider: WorkspaceMacSelectionIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults
        )
        await store.loadPairedMacs()
        return store
    }

    private func workspace(id: String, macDeviceID: String) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            macDeviceID: macDeviceID,
            name: "Workspace",
            terminals: []
        )
    }

    private func pairedMac(
        id: String,
        name: String,
        route: CmxAttachRoute? = nil,
        lastSeenAt: TimeInterval,
        isActive: Bool = false,
        customName: String? = nil
    ) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: name,
            routes: route.map { [$0] } ?? [],
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: lastSeenAt),
            isActive: isActive,
            stackUserID: "user-1",
            teamID: "team-a",
            customName: customName
        )
    }

    private func route(host: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "route-\(host)",
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: 50922)
        )
    }
}
