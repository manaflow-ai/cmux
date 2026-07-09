public import AuthenticationServices
#if DEBUG
internal import CMUXDebugLog
#endif

extension BrowserWebAuthnCreationRequest {
    /// Builds the native authorization plan for this credential-creation request,
    /// or nil when no platform or security-key request is available on this OS.
    @MainActor
    public func nativeRequestPlan(
        clientDataContext: BrowserWebAuthnClientDataContext
    ) throws -> BrowserWebAuthnNativeRequestPlan? {
        guard let userName = publicKey.user.name, !userName.isEmpty else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }

        guard let relyingPartyIdentifier = try clientDataContext.resolveRelyingPartyIdentifier(
            publicKey.rp?.id
        ) else {
            return nil
        }
        let clientData = try clientDataContext.clientData(challenge: publicKey.challenge.data)
        let selection = publicKey.authenticatorSelection
        let attachment = selection?.attachment
        let requestedAlgorithms = publicKey.requestedAlgorithms

        guard !requestedAlgorithms.isEmpty else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }

        var platformRequests: [ASAuthorizationRequest] = []
        if #available(macOS 13.5, *),
           requestedAlgorithms.contains(-7) {
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
                relyingPartyIdentifier: relyingPartyIdentifier
            )
            let platformRequest = provider.createCredentialRegistrationRequest(
                clientData: clientData,
                name: userName,
                userID: publicKey.user.id.data
            )
            platformRequest.displayName = publicKey.user.displayName ?? userName
            platformRequest.userVerificationPreference = .init(
                rawValue: selection?.userVerificationPreference ?? "preferred"
            )
            platformRequest.attestationPreference = .init(
                rawValue: publicKey.normalizedAttestationPreference
            )
            let excludedCredentials = (publicKey.excludeCredentials ?? [])
                .compactMap { $0.platformDescriptor() }
            if !excludedCredentials.isEmpty {
                platformRequest.excludedCredentials = excludedCredentials
            }
            platformRequest.shouldShowHybridTransport = attachment != "platform"
            platformRequests.append(platformRequest)
        }

        var securityKeyRequests: [ASAuthorizationRequest] = []
        if attachment != "platform",
           #available(macOS 14.4, *) {
            let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
                relyingPartyIdentifier: relyingPartyIdentifier
            )
            let securityKeyRequest = provider.createCredentialRegistrationRequest(
                clientData: clientData,
                displayName: publicKey.user.displayName ?? userName,
                name: userName,
                userID: publicKey.user.id.data
            )

            securityKeyRequest.credentialParameters = publicKey.pubKeyCredParams
                .compactMap { $0.securityKeyCredentialParameter() }
            if securityKeyRequest.credentialParameters.isEmpty {
                throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
            }

            securityKeyRequest.userVerificationPreference = .init(
                rawValue: selection?.userVerificationPreference ?? "preferred"
            )
            securityKeyRequest.residentKeyPreference = .init(
                rawValue: selection?.residentKeyPreference ?? "discouraged"
            )
            securityKeyRequest.attestationPreference = .init(
                rawValue: publicKey.normalizedAttestationPreference
            )
            let excludedCredentials = (publicKey.excludeCredentials ?? [])
                .compactMap { $0.securityKeyDescriptor() }
            if !excludedCredentials.isEmpty {
                securityKeyRequest.excludedCredentials = excludedCredentials
            }
            securityKeyRequests.append(securityKeyRequest)
        }

        guard !platformRequests.isEmpty || !securityKeyRequests.isEmpty else {
            #if DEBUG
            CMUXDebugLog.logDebugEvent("webauthn.buildCreationPlan no requests built — returning nil")
            #endif
            return nil
        }

        #if DEBUG
        CMUXDebugLog.logDebugEvent("webauthn.buildCreationPlan rp=\(relyingPartyIdentifier) platform=\(platformRequests.count) securityKey=\(securityKeyRequests.count) attachment=\(attachment ?? "(nil)")")
        #endif
        return .init(
            platformRequests: platformRequests,
            securityKeyRequests: securityKeyRequests,
            order: attachment == "cross-platform" ? .securityKeyFirst : .platformFirst,
            needsBluetoothForPlatformRequests: attachment != "platform",
            needsBluetoothForSecurityKeyRequests: false,
            prefersImmediatelyAvailableCredentials: false
        )
    }
}
