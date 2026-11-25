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

    /// `socket`: this Mac's daemon socket, read per start.
    public init(cli: BundledExecutable, auth: CloudAuth, socket: @escaping @MainActor () async -> String?) {
        call = CloudCLICall(cli: cli)
        self.auth = auth
        self.socket = socket
    }

    /// The sheet's create: the outcome of one start under the sheet's key; `opened` shows the Chief's conversation.
    public func create(opened: @escaping @MainActor (ConversationID) -> Void) -> (String, String) async -> HomeComposeOutcome {
        { [call, auth, socket] name, key in
            guard auth.isSignedIn else { return .offline }
            switch await call.startChiefOnMachine(key: key, name: name, signedIn: auth, socket: await socket()) {
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
