/// Backend capabilities that change which composer actions are truthful.
public struct ChatComposerCapabilities: Sendable, Equatable {
    public let allowsTextSend: Bool
    public let allowsAttachments: Bool
    public let allowsInterrupt: Bool
    public let allowsHardInterrupt: Bool
    public let allowsOfflineSendQueue: Bool

    public init(
        allowsTextSend: Bool = true,
        allowsAttachments: Bool = true,
        allowsInterrupt: Bool = true,
        allowsHardInterrupt: Bool = true,
        allowsOfflineSendQueue: Bool = false
    ) {
        self.allowsTextSend = allowsTextSend
        self.allowsAttachments = allowsAttachments
        self.allowsInterrupt = allowsInterrupt
        self.allowsHardInterrupt = allowsHardInterrupt
        self.allowsOfflineSendQueue = allowsOfflineSendQueue
    }

    public static let all = ChatComposerCapabilities()
    public static let textOnly = ChatComposerCapabilities(
        allowsAttachments: false,
        allowsOfflineSendQueue: true
    )
    public static let readOnly = ChatComposerCapabilities(
        allowsTextSend: false,
        allowsAttachments: false,
        allowsInterrupt: false,
        allowsHardInterrupt: false,
        allowsOfflineSendQueue: false
    )
}

struct ChatComposerSendPolicy {
    static func canSubmit(isConnected: Bool, capabilities: ChatComposerCapabilities) -> Bool {
        capabilities.allowsTextSend
            && (isConnected || capabilities.allowsOfflineSendQueue)
    }
}
