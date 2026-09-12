import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite struct DeclarativeTerminalConfigurationModelTests {
    @Test func pickerWritesPublishImmediatelyAndReconcileWithJSON() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("declarative-terminal-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "DeclarativeTerminalConfigurationModelTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let catalog = SettingCatalog()
        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let policyStream = store.valuesIfPresent(for: catalog.terminal.newSurfaceWorkingDirectoryPolicy)
        var policyIterator = policyStream.makeAsyncIterator()
        let modeStream = store.values(for: catalog.terminal.shellStartupMode)
        var modeIterator = modeStream.makeAsyncIterator()
        let model = DeclarativeTerminalConfigurationModel(
            jsonStore: store,
            userDefaultsStore: makeTestUserDefaultsStore(suiteName: suiteName),
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )

        let initialPolicy = await policyIterator.next()
        guard let initialPolicy else {
            Issue.record("Expected an initial policy stream element")
            return
        }
        #expect(initialPolicy == nil)
        #expect(await modeIterator.next() == .login)

        model.startObserving()
        await model.waitForInitialSnapshot()

        model.setWorkingDirectoryPolicy(.fixedPath)
        model.setShellStartupMode(.nonLogin)

        #expect(model.values.effectiveWorkingDirectoryPolicy() == .fixedPath)
        #expect(model.values.shellStartupMode == .nonLogin)
        #expect(await policyIterator.next() == .fixedPath)
        #expect(await modeIterator.next() == .nonLogin)
    }

    @Test func fixedPathChangesFailClosedUntilInitialValidation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("declarative-terminal-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "DeclarativeTerminalConfigurationModelTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let catalog = SettingCatalog()
        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let model = DeclarativeTerminalConfigurationModel(
            jsonStore: store,
            userDefaultsStore: makeTestUserDefaultsStore(suiteName: suiteName),
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )

        model.startObserving()
        await model.waitForInitialSnapshot()

        model.setWorkingDirectoryPolicy(.fixedPath)
        model.setWorkingDirectoryPath(directory.path)

        #expect(!model.values.fixedPathIsUsable)
        await waitUntil { model.values.fixedPathIsUsable }
        #expect(model.values.fixedPathIsUsable)

        let missingPath = directory.appendingPathComponent("missing", isDirectory: true).path
        model.setWorkingDirectoryPath(missingPath)

        #expect(!model.values.fixedPathIsUsable)
        await waitUntil { model.values.expandedWorkingDirectoryPath == missingPath }
        #expect(!model.values.fixedPathIsUsable)
    }

    @Test(arguments: [false, true])
    func fixedPathValidationRecoversAfterDirectoryRecreation(initiallyMissing: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("declarative-terminal-model-\(UUID().uuidString)", isDirectory: true)
        let fixedPath = directory.appendingPathComponent("nested/fixed", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !initiallyMissing {
            try FileManager.default.createDirectory(at: fixedPath, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "DeclarativeTerminalConfigurationModelTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let catalog = SettingCatalog()
        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let model = DeclarativeTerminalConfigurationModel(
            jsonStore: store,
            userDefaultsStore: makeTestUserDefaultsStore(suiteName: suiteName),
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )

        model.startObserving()
        await model.waitForInitialSnapshot()
        model.setWorkingDirectoryPolicy(.fixedPath)
        model.setWorkingDirectoryPath(fixedPath.path)
        if initiallyMissing {
            #expect(!model.values.fixedPathIsUsable)
            try FileManager.default.createDirectory(at: fixedPath, withIntermediateDirectories: true)
        }
        try #require(await waitUntil { model.values.fixedPathIsUsable })

        try FileManager.default.removeItem(at: fixedPath)
        try #require(await waitUntil { !model.values.fixedPathIsUsable })

        try FileManager.default.createDirectory(at: fixedPath, withIntermediateDirectories: true)
        try #require(await waitUntil { model.values.fixedPathIsUsable })
        #expect(model.values.fixedPathIsUsable)
    }

    @Test func externalSnapshotSupersedesCompletedPendingWrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("declarative-terminal-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "DeclarativeTerminalConfigurationModelTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let catalog = SettingCatalog()
        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let model = DeclarativeTerminalConfigurationModel(
            jsonStore: store,
            userDefaultsStore: makeTestUserDefaultsStore(suiteName: suiteName),
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )

        model.startObserving()
        await model.waitForInitialSnapshot()

        let shellStartupModeKey = catalog.terminal.shellStartupMode
        let ready = AsyncStream<Void>.makeStream()
        var readyIterator = ready.stream.makeAsyncIterator()
        let externalEdit = Task.detached {
            var iterator = store.snapshots().makeAsyncIterator()
            _ = await iterator.next()
            ready.continuation.yield(())
            _ = await iterator.next()
            try? await store.set(.login, for: shellStartupModeKey)
        }

        _ = await readyIterator.next()
        model.setShellStartupMode(.nonLogin)
        await externalEdit.value
        await waitUntil { model.values.shellStartupMode == .login }

        #expect(model.values.shellStartupMode == .login)
    }

    @Test(arguments: [false, true])
    func externalEditBeforeFirstSubscriptionIsDelivered(initiallyMissing: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("declarative-terminal-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("cmux.json")
        if !initiallyMissing {
            try Data(#"{"terminal":{"shellStartup":{"mode":"login"}}}"#.utf8)
                .write(to: fileURL, options: .atomic)
        }
        let store = JSONConfigStore(fileURL: fileURL)
        let cached = await store.coherentSnapshot()
        #expect(DeclarativeTerminalConfiguration().snapshot(data: cached.data).shellStartupMode == .login)

        try Data(#"{"terminal":{"shellStartup":{"mode":"nonLogin"}}}"#.utf8)
            .write(to: fileURL, options: .atomic)

        let suiteName = "DeclarativeTerminalConfigurationModelTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let model = DeclarativeTerminalConfigurationModel(
            jsonStore: store,
            userDefaultsStore: makeTestUserDefaultsStore(suiteName: suiteName),
            catalog: SettingCatalog(),
            errorLog: SettingsErrorLog()
        )

        model.startObserving()
        await model.waitForInitialSnapshot()
        try #require(await waitUntil { model.values.shellStartupMode == .nonLogin })
    }

    @Test func newerExternalSnapshotWinsOverRefreshStartedEarlier() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("declarative-terminal-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "DeclarativeTerminalConfigurationModelTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let catalog = SettingCatalog()
        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let model = DeclarativeTerminalConfigurationModel(
            jsonStore: store,
            userDefaultsStore: makeTestUserDefaultsStore(suiteName: suiteName),
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )

        try await store.set(.login, for: catalog.terminal.shellStartupMode)
        let earlierRefresh = await store.coherentSnapshot()
        try await store.set(.nonLogin, for: catalog.terminal.shellStartupMode)
        let externalSnapshot = await store.coherentSnapshot()

        await model.apply(externalSnapshot)
        #expect(model.values.shellStartupMode == .nonLogin)
        await model.apply(earlierRefresh)

        #expect(model.values.shellStartupMode == .nonLogin)
    }

    @discardableResult
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        return condition()
    }
}

private func makeTestUserDefaultsStore(suiteName: String) -> UserDefaultsSettingsStore {
    UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
}
