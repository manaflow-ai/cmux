internal import CMUXMobileCore

extension CmxAttachTicket {
    func replacingRoutes(_ routes: [CmxAttachRoute]) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            version: version,
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName,
            macUserEmail: macUserEmail,
            macUserID: macUserID,
            macPairingCompatibilityVersion: macPairingCompatibilityVersion,
            macAppVersion: macAppVersion,
            macAppBuild: macAppBuild,
            routes: routes,
            expiresAt: expiresAt,
            authToken: authToken
        )
    }

    func replacingIdentity(macDeviceID: String, routes: [CmxAttachRoute]) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            version: version,
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName,
            macUserEmail: macUserEmail,
            macUserID: macUserID,
            macPairingCompatibilityVersion: macPairingCompatibilityVersion,
            macAppVersion: macAppVersion,
            macAppBuild: macAppBuild,
            routes: routes,
            expiresAt: expiresAt,
            authToken: authToken
        )
    }

    func constrainingRoutes(
        to routes: [CmxAttachRoute],
        fallbackDisplayName: String
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName ?? fallbackDisplayName,
            macUserEmail: macUserEmail,
            macUserID: macUserID,
            macPairingCompatibilityVersion: macPairingCompatibilityVersion,
            macAppVersion: macAppVersion,
            macAppBuild: macAppBuild,
            routes: routes,
            expiresAt: expiresAt,
            authToken: authToken
        )
    }
}
