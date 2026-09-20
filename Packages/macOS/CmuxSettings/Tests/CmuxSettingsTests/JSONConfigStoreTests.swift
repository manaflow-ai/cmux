import Foundation
import Testing
@testable import CmuxSettings

@Suite("JSONConfigStore")
struct JSONConfigStoreTests {
    private func makeStore() -> (JSONConfigStore, URL, SettingCatalog) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        return (JSONConfigStore(fileURL: fileURL), fileURL, SettingCatalog())
    }

    @Test(arguments: [
        #"{"app": 1, "app": {"appearance": "dark"}}"#,
        #"{"app": {"appearance": "shadowed", "keep": 1}, "app": {"appearance": "dark"}}"#,
        #"{"app": {"nested": 1, "nested": {"appearance": "dark"}}}"#,
    ])
    func resetUsesEffectiveDuplicateAncestors(source: String) async throws {
        let (store, fileURL, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try Data(source.utf8).write(to: fileURL)
        let path = source.contains("nested") ? "app.nested.appearance" : "app.appearance"
        let key = JSONKey<String>(id: path, defaultValue: "default")
        try await store.reset(key)
        #expect(await store.value(for: key) == "default")
        let fresh = JSONConfigStore(fileURL: fileURL)
        #expect(await fresh.value(for: key) == "default")
        let updated = try String(contentsOf: fileURL, encoding: .utf8)
        if source.contains("shadowed") {
            #expect(updated.contains(#""keep": 1"#))
        }
    }

    @Test(arguments: [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian])
    func editsPreserveSourceEncodingAndBOM(encoding: String.Encoding) async throws {
        let (store, fileURL, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let source = "\u{feff}" + #"{"app": {"appearance": "dark"}}"#
        let original = try #require(source.data(using: encoding))
        try original.write(to: fileURL)
        let key = JSONKey<String>(id: "app.appearance", defaultValue: "system")
        try await store.set("light", for: key)
        let expected = try #require(source.replacingOccurrences(of: "dark", with: "light").data(using: encoding))
        #expect(try Data(contentsOf: fileURL) == expected)
        #expect(await JSONConfigStore(fileURL: fileURL).value(for: key) == "light")
        try await store.reset(key)
        let resetBytes = try Data(contentsOf: fileURL)
        let marker = try #require("\u{feff}".data(using: encoding))
        #expect(resetBytes.starts(with: marker))
        let resetText = try #require(String(data: resetBytes, encoding: encoding))
        #expect(!resetText.contains("appearance"))
    }

    @Test func readsDefaultWhenFileMissing() async {
        let (store, _, _) = makeStore()
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "")
    }

    @Test func roundTripsNestedKey() async throws {
        let (store, fileURL, _) = makeStore()
        try await store.set("hunter2", for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "hunter2")

        let data = try Data(contentsOf: fileURL)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let automation = parsed?["automation"] as? [String: Any]
        #expect(automation?["socketPassword"] as? String == "hunter2")
    }

    @Test func resetRemovesEntryAndPrunesEmptyParents() async throws {
        let (store, fileURL, _) = makeStore()
        try await store.set("hunter2", for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        try await store.reset(JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "")
        let data = try Data(contentsOf: fileURL)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["automation"] == nil)
    }

    @Test func toleratesJSONCComments() async throws {
        let (store, fileURL, _) = makeStore()
        let json = """
        {
          // commented
          "automation": {
            "socketPassword": "test",
          }
        }
        """
        try Data(json.utf8).write(to: fileURL)
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "test")
    }

    @Test func observesExternalEdit() async throws {
        let (store, fileURL, _) = makeStore()
        try Data("{}".utf8).write(to: fileURL)

        let key = JSONKey<String>(id: "automation.socketPassword", defaultValue: "")
        let payload = #"{"automation":{"socketPassword":"injected"}}"#

        // Ready-handshake, used by every observation test here: wait for the
        // observer to consume the initial value before any external activity,
        // so the first collected element never races the writer.
        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let observed = Task<[String], Never> {
            var collected: [String] = []
            for await value in store.values(for: key) {
                collected.append(value)
                if collected.count == 1 { readyContinuation.yield() }
                if collected.last == "injected" { break }
            }
            return collected
        }

        await withTimeout(seconds: 8) {
            var it = ready.makeAsyncIterator()
            _ = await it.next()
        }

        let writer = Task {
            var bump = Date()
            while !Task.isCancelled {
                try? Data(payload.utf8).write(to: fileURL)
                bump = bump.addingTimeInterval(1)
                try? FileManager.default.setAttributes(
                    [.modificationDate: bump], ofItemAtPath: fileURL.path
                )
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        let collected = await withTimeout(seconds: 8) { await observed.value }
        writer.cancel()
        #expect(collected.first == "")
        #expect(collected.last == "injected")
    }

    @Test func snapshotReflectsWrites() async throws {
        let (store, _, _) = makeStore()
        let key = JSONKey<String>(id: "app.devWindowDisplay", defaultValue: "")
        #expect(store.snapshotValue(for: key) == "")

        try await store.set("LG HDR 4K", for: key)
        #expect(store.snapshotValue(for: key) == "LG HDR 4K")

        try await store.reset(key)
        #expect(store.snapshotValue(for: key) == "")
    }

    @Test func snapshotMatchesAsyncRead() async throws {
        let (store, _, _) = makeStore()
        let key = JSONKey<String>(id: "automation.socketPassword", defaultValue: "")
        try await store.set("hunter2", for: key)
        let async = await store.value(for: key)
        #expect(store.snapshotValue(for: key) == async)
    }

    @Test func snapshotReadsOnDiskValueForFreshStore() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        let payload = #"{"app":{"devWindowDisplay":"LG HDR 4K"}}"#
        try Data(payload.utf8).write(to: fileURL)

        // Brand-new store, no async read first: the synchronous read goes
        // straight to disk and reflects the on-disk value.
        let store = JSONConfigStore(fileURL: fileURL)
        let key = JSONKey<String>(id: "app.devWindowDisplay", defaultValue: "")
        #expect(store.snapshotValue(for: key) == "LG HDR 4K")
    }

    @Test func snapshotReflectsExternalEdit() async throws {
        let (store, fileURL, _) = makeStore()
        let key = JSONKey<String>(id: "app.devWindowDisplay", defaultValue: "")
        #expect(store.snapshotValue(for: key) == "")

        // A direct disk read picks up an external edit immediately, with no
        // observer subscription or actor round-trip.
        try Data(#"{"app":{"devWindowDisplay":"LG HDR 4K"}}"#.utf8).write(to: fileURL)
        #expect(store.snapshotValue(for: key) == "LG HDR 4K")
    }

    @Test func devWindowDisplayCatalogKeyRoundTripsToSharedPath() async throws {
        let (store, fileURL, catalog) = makeStore()
        try await store.set("LG HDR 4K", for: catalog.app.devWindowDisplay)

        // Async and sync reads agree on the catalog key.
        #expect(await store.value(for: catalog.app.devWindowDisplay) == "LG HDR 4K")
        #expect(store.snapshotValue(for: catalog.app.devWindowDisplay) == "LG HDR 4K")

        // It lands at app.devWindowDisplay in cmux.json — the shared on-disk
        // shape the CLI, the app's window hook, and the Debug menu all read.
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let app = parsed?["app"] as? [String: Any]
        #expect(app?["devWindowDisplay"] as? String == "LG HDR 4K")

        try await store.reset(catalog.app.devWindowDisplay)
        #expect(store.snapshotValue(for: catalog.app.devWindowDisplay) == "")
    }


    @Test func setPreservesCommentsWhitespaceOrderingAndTrailingCommas() async throws {
        let (store, fileURL, _) = makeStore()
        let source = """
        {
          // root documentation
          "zeta": { "keep": true },
          "app": {
            // before appearance
            "before": 1,
            "appearance": "light", // inline appearance documentation
            // after appearance
            "after": 2,
          },
          "alpha": 1,
        }
        """ + "\n"
        try Data(source.utf8).write(to: fileURL)

        let key = JSONKey<String>(id: "app.appearance", defaultValue: "system")
        try await store.set("dark", for: key)

        let updated = try String(contentsOf: fileURL, encoding: .utf8)
        let expected = source.replacingOccurrences(
            of: "\"appearance\": \"light\"",
            with: "\"appearance\": \"dark\""
        )
        #expect(updated == expected)
    }

    @Test func setCreatesNestedPathWithExistingTrailingCommaStyle() async throws {
        let (store, fileURL, _) = makeStore()
        let source = """
        {
          "app": {
            "appearance": "dark",
          },
          "other": 1,
        }
        """ + "\n"
        try Data(source.utf8).write(to: fileURL)

        let key = JSONKey<Bool>(id: "app.nested.leaf", defaultValue: false)
        try await store.set(true, for: key)

        let updated = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(updated.contains(
            """
            "nested": {
                  "leaf": true
                },
            """
        ))
        #expect(updated.range(of: "\"app\"")!.lowerBound < updated.range(of: "\"other\"")!.lowerBound)

        let sanitized = try JSONCSanitizer().sanitize(Data(updated.utf8))
        let parsed = try JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        let app = parsed?["app"] as? [String: Any]
        let nested = app?["nested"] as? [String: Any]
        #expect(nested?["leaf"] as? Bool == true)
    }

    @Test func resetRemovesNestedPathAndPrunesPlainEmptyParentsLosslessly() async throws {
        let (store, fileURL, _) = makeStore()
        let source = """
        {
          "automation": {
            "nested": {
              "leaf": true,
            },
          },
          "keep": 1,
        }
        """ + "\n"
        try Data(source.utf8).write(to: fileURL)

        let key = JSONKey<Bool>(id: "automation.nested.leaf", defaultValue: false)
        try await store.reset(key)

        let updated = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(updated == """
        {
          "keep": 1,
        }

        """)
    }

    @Test func resetKeepsDocumentationInsideNowEmptyParent() async throws {
        let (store, fileURL, _) = makeStore()
        let source = """
        {
          "automation": {
            // Why this section exists.
            "socketPassword": "secret",
          },
          "keep": true,
        }
        """ + "\n"
        try Data(source.utf8).write(to: fileURL)

        let key = JSONKey<String>(id: "automation.socketPassword", defaultValue: "")
        try await store.reset(key)

        let updated = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(updated.contains("// Why this section exists."))
        #expect(!updated.contains("\"socketPassword\""))
        #expect(updated.contains("\"keep\": true,"))
    }

    @Test func setThroughSymlinkEditsTargetAndKeepsLink() async throws {
        let (store, fileURL, _) = makeStore()
        let targetURL = fileURL.deletingLastPathComponent().appendingPathComponent("target.json")
        let source = """
        {
          // target docs
          "app": {
            "appearance": "light",
          },
        }
        """ + "\n"
        try Data(source.utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            atPath: fileURL.path,
            withDestinationPath: targetURL.path
        )

        let key = JSONKey<String>(id: "app.appearance", defaultValue: "system")
        try await store.set("dark", for: key)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)
        #expect(destination == targetURL.path)
        let target = try String(contentsOf: targetURL, encoding: .utf8)
        #expect(target == source.replacingOccurrences(
            of: "\"appearance\": \"light\"",
            with: "\"appearance\": \"dark\""
        ))
    }

    @Test func malformedConfigRefusesMutationWithoutChangingBytes() async throws {
        let (store, fileURL, _) = makeStore()
        let malformed = Data(
            """
            {
              // truncated object
              "app": {
                "appearance": "light",

            """.utf8
        )
        try malformed.write(to: fileURL)

        let key = JSONKey<String>(id: "app.appearance", defaultValue: "system")
        var didThrow = false
        do {
            try await store.set("dark", for: key)
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(try Data(contentsOf: fileURL) == malformed)
    }

    @Test func semanticNoOpsAreByteStableAndSkipAtomicReplace() async throws {
        let (store, fileURL, _) = makeStore()
        let source = """
        {
          // preserve every byte on no-op
          "app": {
            "appearance": "dark",
          },
        }
        """ + "\n"
        try Data(source.utf8).write(to: fileURL)
        let marker = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: marker],
            ofItemAtPath: fileURL.path
        )
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modifiedBefore = attributesBefore[.modificationDate] as? Date
        let bytesBefore = try Data(contentsOf: fileURL)

        try await store.set(
            "dark",
            for: JSONKey<String>(id: "app.appearance", defaultValue: "system")
        )
        try await store.reset(
            JSONKey<String>(id: "app.missing", defaultValue: "")
        )

        let attributesAfter = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modifiedAfter = attributesAfter[.modificationDate] as? Date
        #expect(try Data(contentsOf: fileURL) == bytesBefore)
        #expect(modifiedAfter == modifiedBefore)
    }


    @Test func setTargetsFoundationEffectiveDuplicateKey() async throws {
        let (store, fileURL, _) = makeStore()
        let source = """
        {
          "app": {
            "appearance": "shadowed",
            "appearance": "system",
          },
        }
        """ + "\n"
        try Data(source.utf8).write(to: fileURL)

        let key = JSONKey<String>(id: "app.appearance", defaultValue: "default")
        try await store.set("dark", for: key)

        let updated = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(updated.contains("\"appearance\": \"system\""))
        #expect(updated.contains("\"appearance\": \"dark\""))
        #expect(await store.value(for: key) == "dark")
    }

    @Test(arguments: [
        #"{"app": 1, "app": {"appearance": "shadowed"}}"#,
        #"{"app": {"appearance": "old"}, "app": {"appearance": "shadowed"}}"#,
        #"{"app": {"appearance": "old"}, "app": 1}"#,
        #"{"app": {"appearance": "old", "appearance": "shadowed"}}"#,
    ])
    func setDuplicatePathsAgreesWithFreshFoundationRead(source: String) async throws {
        let (store, fileURL, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try Data(source.utf8).write(to: fileURL)
        let key = JSONKey<String>(id: "app.appearance", defaultValue: "system")
        try await store.set("light", for: key)
        #expect(await store.value(for: key) == "light")
        #expect(await JSONConfigStore(fileURL: fileURL).value(for: key) == "light")
        let bytes = try Data(contentsOf: fileURL)
        let root = try #require(JSONSerialization.jsonObject(with: JSONCSanitizer().sanitize(bytes)) as? [String: Any])
        let app = try #require(root["app"] as? [String: Any])
        #expect(app["appearance"] as? String == "light")
        if source.contains("shadowed") {
            #expect(String(decoding: bytes, as: UTF8.self).contains("shadowed"))
        }
    }

    @Test func resetDuplicateKeysDoesNotExposeShadowedValue() async throws {
        let (store, fileURL, _) = makeStore()
        let source = """
        {
          "app": {
            "appearance": "shadowed",
            "keep": "authored",
          },
          "app": {
            "appearance": "system",
            "appearance": "light",
          },
          "other": 1,
        }
        """ + "\n"
        try Data(source.utf8).write(to: fileURL)

        let key = JSONKey<String>(id: "app.appearance", defaultValue: "default")
        try await store.reset(key)

        let updated = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(updated.contains("\"keep\": \"authored\""))
        #expect(updated.contains("\"other\": 1"))
        #expect(await store.value(for: key) == "default")

        let sanitized = try JSONCSanitizer().sanitize(Data(updated.utf8))
        let parsed = try JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        let app = parsed?["app"] as? [String: Any]
        #expect(app?["appearance"] == nil)
    }

}
