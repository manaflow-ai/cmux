/// A derived summary of the transports requested across a set of credential
/// descriptors, used to decide which native authenticator request types to build.
public struct BrowserWebAuthnTransportSummary {
    public let containsBluetooth: Bool
    public let containsHybrid: Bool
    public let containsInternal: Bool
    public let containsSecurityKeyTransport: Bool
    public let containsUnspecifiedTransport: Bool

    public init(descriptors: [BrowserWebAuthnCredentialDescriptor]) {
        var containsBluetooth = false
        var containsHybrid = false
        var containsInternal = false
        var containsSecurityKeyTransport = false
        var containsUnspecifiedTransport = false

        for descriptor in descriptors where descriptor.isPublicKeyCredential {
            let transports = descriptor.normalizedTransports
            if transports.isEmpty {
                containsUnspecifiedTransport = true
                continue
            }

            for transport in transports {
                switch transport {
                case .ble:
                    containsBluetooth = true
                    containsSecurityKeyTransport = true
                case .hybrid:
                    containsHybrid = true
                case .internal:
                    containsInternal = true
                case .nfc, .usb:
                    containsSecurityKeyTransport = true
                }
            }
        }

        self.containsBluetooth = containsBluetooth
        self.containsHybrid = containsHybrid
        self.containsInternal = containsInternal
        self.containsSecurityKeyTransport = containsSecurityKeyTransport
        self.containsUnspecifiedTransport = containsUnspecifiedTransport
    }

    public var allowsPlatformCredentials: Bool {
        containsInternal || containsHybrid || containsUnspecifiedTransport
    }

    public var allowsSecurityKeyCredentials: Bool {
        containsSecurityKeyTransport || containsHybrid || containsUnspecifiedTransport
    }

    public var needsBluetoothPreparation: Bool {
        containsBluetooth || containsHybrid
    }

    public var prefersSecurityKeysFirst: Bool {
        containsSecurityKeyTransport &&
            !containsInternal &&
            !containsHybrid &&
            !containsUnspecifiedTransport
    }

    public var shouldShowHybridTransport: Bool {
        containsHybrid || containsUnspecifiedTransport
    }
}
