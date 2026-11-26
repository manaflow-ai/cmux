public import CmuxHomeCore
public import CmuxNextCloud
public import CmuxNextDaemon
public import CmuxNextHomeModel

/// New Chief's "On its own Cloud machine" (``HomeNewChiefSheet/onCreateOnMachine``): a Chief on a Cloud machine of its
/// own, which the Rust `machine.chief_start` makes, pairs, keeps from idle-pausing and starts the host on
/// (``CloudCLICall/startChiefOnMachine(key:name:signedIn:socket:)``). The hosted Chief path is untouched.
@MainActor
public struct HomeMachineChiefStart {
    let call: CloudCLICall
    let auth: CloudAuth
    let socket: @MainActor () async -> String?
    let credentials: CloudAgentCredentials?

    /// `socket`: this Mac's daemon socket, read per start. `credentials`: the app's agent credentials, from which each start
    /// reads the owner's Claude connection (Cloud first use's pick for `claude`) for the Chief's turns on its machine
    /// (nil, or no such connection: the start as before).
    public init(cli: BundledExecutable, auth: CloudAuth, socket: @escaping @MainActor () async -> String?,
                credentials: CloudAgentCredentials? = nil) {
        call = CloudCLICall(cli: cli)
        self.auth = auth
        self.socket = socket
        self.credentials = credentials
    }

    /// The owner's Claude connection's env, read now; nil when there is none or it cannot be read.
    static func turnEnv(_ credentials: CloudAgentCredentials?) async -> [String: String]? {
        guard let credentials,
              let id = await credentials.setup?.choose(harness: "claude", model: nil, account: nil).connectionID else { return nil }
        return try? await credentials.credential(forConnection: id).env
    }

    /// The sheet's create: the outcome of one start under the sheet's key; `opened` shows the Chief's conversation.
    public func create(opened: @escaping @MainActor (ConversationID) -> Void) -> (String, String) async -> HomeComposeOutcome {
        { [call, auth, socket, credentials] name, key in
            guard auth.isSignedIn else { return .offline }
            switch await call.startChiefOnMachine(key: key, name: name, signedIn: auth, socket: await socket(),
                                                  turnEnv: await Self.turnEnv(credentials)) {
            case .success(let conversation):
                let id = ConversationID(conversation)
                opened(id)
                return .opened(id)
            case .failure(let refusal) where refusal.code == "not_signed_in":
                return .offline
            case .failure(let refusal):
                return refusal.message.isEmpty ? .refusal(code: refusal.code) : .refused(refusal.message)
            }
        }
    }
}
