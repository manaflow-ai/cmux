import Foundation
import WebKit

@available(macOS 15.4, *)
struct BrowserWebExtensionPermissionState: Codable, Equatable {
    var grantedPermissions: [String: Date] = [:]
    var deniedPermissions: [String: Date] = [:]
    var grantedPermissionMatchPatterns: [String: Date] = [:]
    var deniedPermissionMatchPatterns: [String: Date] = [:]
    var hasRequestedOptionalAccessToAllHosts = false
    var hasAccessToPrivateData = false

    init(
        grantedPermissions: [String: Date] = [:],
        deniedPermissions: [String: Date] = [:],
        grantedPermissionMatchPatterns: [String: Date] = [:],
        deniedPermissionMatchPatterns: [String: Date] = [:],
        hasRequestedOptionalAccessToAllHosts: Bool = false,
        hasAccessToPrivateData: Bool = false
    ) {
        self.grantedPermissions = grantedPermissions
        self.deniedPermissions = deniedPermissions
        self.grantedPermissionMatchPatterns = grantedPermissionMatchPatterns
        self.deniedPermissionMatchPatterns = deniedPermissionMatchPatterns
        self.hasRequestedOptionalAccessToAllHosts = hasRequestedOptionalAccessToAllHosts
        self.hasAccessToPrivateData = hasAccessToPrivateData
    }

    init(context: WKWebExtensionContext) {
        grantedPermissions = Self.permissionState(context.grantedPermissions)
        deniedPermissions = Self.permissionState(context.deniedPermissions)
        grantedPermissionMatchPatterns = Self.matchPatternState(context.grantedPermissionMatchPatterns)
        deniedPermissionMatchPatterns = Self.matchPatternState(context.deniedPermissionMatchPatterns)
        hasRequestedOptionalAccessToAllHosts = context.hasRequestedOptionalAccessToAllHosts
        hasAccessToPrivateData = context.hasAccessToPrivateData
    }

    func apply(to context: WKWebExtensionContext) {
        context.grantedPermissions = Self.permissionDictionary(grantedPermissions)
        context.deniedPermissions = Self.permissionDictionary(deniedPermissions)
        context.grantedPermissionMatchPatterns = Self.matchPatternDictionary(grantedPermissionMatchPatterns)
        context.deniedPermissionMatchPatterns = Self.matchPatternDictionary(deniedPermissionMatchPatterns)
        context.hasRequestedOptionalAccessToAllHosts = hasRequestedOptionalAccessToAllHosts
        context.hasAccessToPrivateData = hasAccessToPrivateData
    }

    private static func permissionState(_ values: [WKWebExtension.Permission: Date]) -> [String: Date] {
        var state: [String: Date] = [:]
        for (permission, expirationDate) in values {
            state[permission.rawValue] = expirationDate
        }
        return state
    }

    private static func matchPatternState(_ values: [WKWebExtension.MatchPattern: Date]) -> [String: Date] {
        var state: [String: Date] = [:]
        for (matchPattern, expirationDate) in values {
            state[matchPattern.string] = expirationDate
        }
        return state
    }

    private static func permissionDictionary(_ values: [String: Date]) -> [WKWebExtension.Permission: Date] {
        let now = Date()
        return Dictionary(uniqueKeysWithValues: values.compactMap { rawValue, expirationDate in
            guard expirationDate > now else { return nil }
            return (WKWebExtension.Permission(rawValue: rawValue), expirationDate)
        })
    }

    private static func matchPatternDictionary(_ values: [String: Date]) -> [WKWebExtension.MatchPattern: Date] {
        let now = Date()
        return Dictionary(uniqueKeysWithValues: values.compactMap { rawValue, expirationDate in
            guard expirationDate > now,
                  let matchPattern = try? WKWebExtension.MatchPattern(string: rawValue) else {
                return nil
            }
            return (matchPattern, expirationDate)
        })
    }
}
