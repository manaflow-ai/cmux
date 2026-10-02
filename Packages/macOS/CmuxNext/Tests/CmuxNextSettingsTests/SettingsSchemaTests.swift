import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The schema is the one list the Settings window, write validation and the
/// palette read. These tests hold it to the cmux.json parsers: every value
/// the schema allows loads without a diagnostic, every value it refuses
/// loads with one at the same key, and every default is what the app
/// applies when the key is absent.
@Suite struct SettingsSchemaTests {
    static let densities: Set<String> = ["compact", "comfortable"]

    static func diagnostics(for value: JSONValue, at path: [String]) -> [SettingsDiagnostic] {
        var root = JSONValue.object([:])
        root = Self.setting(value, at: path, in: root)
        return CmuxConfigSnapshot.parse(root, validDensities: densities, validMetrics: []).diagnostics
    }

    static func setting(_ value: JSONValue, at path: [String], in root: JSONValue) -> JSONValue {
        guard let head = path.first else { return value }
        var members = root.objectValue ?? [:]
        members[head] = setting(value, at: Array(path.dropFirst()), in: members[head] ?? .object([:]))
        return .object(members)
    }

    static func validSamples(_ descriptor: SettingDescriptor) -> [JSONValue] {
        switch descriptor.kind {
        case .choice(let choices): choices.map { .string($0.value) }
        case .choiceOrNumber(let choices, let number): choices.map { .string($0.value) } + [.number(number.range.upperBound)]
        case .toggle: [true, false]
        case .number(let number): [.number(number.range.lowerBound), .number(number.range.upperBound)]
        case .color: ["#112233", "#11223344"]
        case .sound: ["default", "none", "Glass"]
        case .url: ["", "https://example.com/start", "example.com"]
        case .hostList: [[], ["mail.google.com", "*.example.com"]]
        case .timeRange: [["start": "22:00", "end": "07:30"]]
        }
    }

    static func invalidSamples(_ descriptor: SettingDescriptor) -> [JSONValue] {
        switch descriptor.kind {
        case .choice: ["__not_a_choice__", 3]
        case .choiceOrNumber: ["__not_a_choice__", false]
        case .toggle: ["yes", 1]
        case .number(let number): ["wide", .number(number.range.upperBound + 100)]
        case .color: ["blue", 7]
        case .sound: [5]
        case .url: ["not an address", "ftp://example.com", 4]
        case .hostList: ["mail.google.com", [1]]
        case .timeRange: [["start": "25:00", "end": "07:00"], "22:00-07:00"]
        }
    }

    @Test func everyAllowedValueLoadsWithoutADiagnostic() {
        for descriptor in SettingsSchema.all {
            for value in Self.validSamples(descriptor) {
                #expect(descriptor.accepts(value), "\(descriptor.id) = \(value)")
                let found = Self.diagnostics(for: value, at: descriptor.path).filter { $0.path.hasPrefix(descriptor.id) }
                #expect(found.isEmpty, "\(descriptor.id) = \(value): \(found)")
            }
        }
    }

    @Test func everyRefusedValueLoadsWithADiagnosticAtItsKey() {
        for descriptor in SettingsSchema.all {
            for value in Self.invalidSamples(descriptor) {
                #expect(!descriptor.accepts(value), "\(descriptor.id) = \(value)")
                let found = Self.diagnostics(for: value, at: descriptor.path).filter { $0.path.hasPrefix(descriptor.id) }
                #expect(!found.isEmpty, "the parser ignores \(descriptor.id) = \(value)")
            }
        }
    }

    @Test func defaultsAreValidAndMatchWhatAnEmptyFileApplies() {
        let empty = CmuxConfigSnapshot.parse(.object([:]), validDensities: Self.densities, validMetrics: [])
        for descriptor in SettingsSchema.all {
            if let value = descriptor.defaultValue {
                #expect(descriptor.accepts(value), "\(descriptor.id) default \(value)")
            } else {
                #expect(descriptor.defaultLabel != nil, "\(descriptor.id) has a derived default without a label")
            }
        }
        #expect(SettingsSchema.descriptor(for: ["ui", "animationSpeed"])?.defaultValue == .string(empty.animationSpeed.rawValue))
        #expect(SettingsSchema.descriptor(for: ["window", "titlebar"])?.defaultValue == .string(empty.titlebar.rawValue))
        #expect(SettingsSchema.descriptor(for: ["window", "rail"])?.defaultValue == .string(empty.rail.rawValue))
        #expect(SettingsSchema.descriptor(for: ["browser", "defaultEngine"])?.defaultValue == .string(empty.browserDefaultEngine.rawValue))
        #expect(SettingsSchema.descriptor(for: ["focusRing", "enabled"])?.defaultValue == .bool(empty.focusRing.enabled))
        #expect(SettingsSchema.descriptor(for: ["notifications", "dismissal"])?.defaultValue == .string(empty.notifications.dismissal.rawValue))
        #expect(SettingsSchema.descriptor(for: ["notifications", "attention", "style"])?.defaultValue == .string(empty.attention.style.rawValue))
        #expect(empty.browserNewTabPage == nil)
    }

    @Test func keysAreUniqueAndEverySectionWithKeysIsShown() {
        let ids = SettingsSchema.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for descriptor in SettingsSchema.all {
            #expect(SettingsSchema.settings(in: descriptor.section).contains(descriptor))
        }
    }

    @MainActor
    @Test func densityChoicesAreTheDesignDensities() {
        guard case .choice(let choices)? = SettingsSchema.descriptor(for: ["appearance", "density"])?.kind else {
            Issue.record("density is not a choice")
            return
        }
        #expect(Set(choices.map(\.value)) == Set(Density.allCases.map(\.rawValue)))
        #expect(Self.densities == Set(Density.allCases.map(\.rawValue)))
    }

    /// Toggle Setting on an absent key used to write `true` whatever the
    /// default was, so the first toggle of a default-on setting did nothing.
    @Test func togglingAnAbsentKeyFlipsItsDefault() throws {
        let enabled = try #require(SettingsSchema.descriptor(for: ["focusRing", "enabled"]))
        #expect(enabled.toggledValue(in: .object([:])) == false)
        #expect(enabled.toggledValue(in: ["focusRing": ["enabled": false]]) == true)
        let pinned = try #require(SettingsSchema.descriptor(for: ["browser", "hibernatePinnedTabs"]))
        #expect(pinned.toggledValue(in: .object([:])) == true)
        #expect(SettingsSchema.descriptor(for: ["ui", "animationSpeed"])?.toggledValue(in: .object([:])) == nil)
    }

    @Test func newTabPageAddresses() {
        #expect(BrowserNewTabPage.url(from: "example.com")?.absoluteString == "https://example.com")
        #expect(BrowserNewTabPage.url(from: "http://localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(BrowserNewTabPage.url(from: "javascript:alert(1)") == nil)
        let snapshot = CmuxConfigSnapshot.parse(["browser": ["newTabPage": "https://example.com/"]], validDensities: Self.densities, validMetrics: [])
        #expect(snapshot.browserNewTabPage?.absoluteString == "https://example.com/")
    }
}
