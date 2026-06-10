@_spi(CmuxHostTransport) import CMUXExtensionHostSupport
@_spi(CmuxHostTransport) import CmuxExtensionKit
import AppKit
import ExtensionFoundation
import SwiftUI


// MARK: - Sidebar Extension Grants
private struct CMUXSidebarExtensionGrant: Codable, Equatable {
    var manifestID: String
    var manifestDisplayName: String
    var apiVersion: CmuxExtensionAPIVersion
    var readScopes: Set<CmuxExtensionScope>
    var actionScopes: Set<CmuxExtensionActionScope>
}

struct CMUXSidebarExtensionEffectiveGrant: Equatable {
    var manifest: CmuxExtensionManifest
    var readScopes: Set<CmuxExtensionScope>
    var actionScopes: Set<CmuxExtensionActionScope>

    var needsAdditionalApproval: Bool {
        !readScopes.isSuperset(of: manifest.readScopes) ||
            !actionScopes.isSuperset(of: manifest.actionScopes)
    }

    var hasSensitiveAccess: Bool {
        readScopes.contains { !CMUXSidebarExtensionGrantStore.defaultReadScopes.contains($0) } ||
            actionScopes.contains { !CMUXSidebarExtensionGrantStore.defaultActionScopes.contains($0) }
    }
}

struct CMUXSidebarExtensionGrantStore {
    static let defaultReadScopes: Set<CmuxExtensionScope> = []
    static let defaultActionScopes: Set<CmuxExtensionActionScope> = []

    private static let defaultsKey = "cmuxExtensionSidebar.grants.v1"

    var defaults: UserDefaults = .standard

    func effectiveGrant(
        bundleIdentifier: String,
        manifest: CmuxExtensionManifest
    ) -> CMUXSidebarExtensionEffectiveGrant {
        let requestedReadScopes = Set(manifest.readScopes)
        let requestedActionScopes = Set(manifest.actionScopes)
        guard let grant = storedGrants()[bundleIdentifier],
              grant.manifestID == manifest.id,
              grant.apiVersion == manifest.minimumAPIVersion else {
            return CMUXSidebarExtensionEffectiveGrant(
                manifest: manifest,
                readScopes: requestedReadScopes.intersection(Self.defaultReadScopes),
                actionScopes: requestedActionScopes.intersection(Self.defaultActionScopes)
            )
        }
        return CMUXSidebarExtensionEffectiveGrant(
            manifest: manifest,
            readScopes: requestedReadScopes.intersection(grant.readScopes),
            actionScopes: requestedActionScopes.intersection(grant.actionScopes)
        )
    }

    func grantRequestedAccess(bundleIdentifier: String, manifest: CmuxExtensionManifest) {
        updateGrant(
            bundleIdentifier: bundleIdentifier,
            manifest: manifest,
            readScopes: Set(manifest.readScopes),
            actionScopes: Set(manifest.actionScopes)
        )
    }

    func revokeSensitiveAccess(bundleIdentifier: String, manifest: CmuxExtensionManifest) {
        updateGrant(
            bundleIdentifier: bundleIdentifier,
            manifest: manifest,
            readScopes: Set(manifest.readScopes).intersection(Self.defaultReadScopes),
            actionScopes: Set(manifest.actionScopes).intersection(Self.defaultActionScopes)
        )
    }

    private func updateGrant(
        bundleIdentifier: String,
        manifest: CmuxExtensionManifest,
        readScopes: Set<CmuxExtensionScope>,
        actionScopes: Set<CmuxExtensionActionScope>
    ) {
        var grants = storedGrants()
        grants[bundleIdentifier] = CMUXSidebarExtensionGrant(
            manifestID: manifest.id,
            manifestDisplayName: manifest.displayName,
            apiVersion: manifest.minimumAPIVersion,
            readScopes: readScopes,
            actionScopes: actionScopes
        )
        save(grants)
    }

    private func storedGrants() -> [String: CMUXSidebarExtensionGrant] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CMUXSidebarExtensionGrant].self, from: data)) ?? [:]
    }

    private func save(_ grants: [String: CMUXSidebarExtensionGrant]) {
        if let data = try? JSONEncoder().encode(grants) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

struct CMUXSidebarExtensionLimitedChoiceStore {
    private static let defaultsKey = "cmuxExtensionSidebar.limitedChoices.v1"

    var defaults: UserDefaults = .standard

    func choices() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func insert(_ key: String) {
        var choices = choices()
        choices.insert(key)
        save(choices)
    }

    func remove(_ key: String) {
        var choices = choices()
        choices.remove(key)
        save(choices)
    }

    private func save(_ choices: Set<String>) {
        defaults.set(choices.sorted(), forKey: Self.defaultsKey)
    }
}

