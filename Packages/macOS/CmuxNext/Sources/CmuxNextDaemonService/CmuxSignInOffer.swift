public import CmuxNextActions
import Foundation

/// Where cmux tells a person to sign in, it offers the one Sign In (msg 3790: "everywhere we say sign
/// in, we need to have a button for signing in"). Every Sign In a refusal toast, a Mac Screen card or
/// a page offers runs the same action, `palette.auth.signIn`, as the person's own run, so the menu,
/// palette and these buttons sign in one way.
@MainActor
public struct CmuxSignInOffer {
    /// The refusal reasons that only ask the person to sign in to cmux.
    public let reasons: Set<String>
    let isSignedIn: @MainActor () -> Bool
    /// Starts the cmux sign-in (the person's run of `palette.auth.signIn`).
    public let signIn: @MainActor () -> Void

    /// - Parameters:
    ///   - reasons: The reasons that ask to sign in to cmux; ``signInReasons`` by default.
    ///   - isSignedIn: Whether a cmux account is signed in now: then no reason offers Sign In.
    ///   - signIn: Starts the cmux sign-in.
    public init(reasons: Set<String> = CmuxSignInOffer.signInReasons, isSignedIn: @escaping @MainActor () -> Bool,
                signIn: @escaping @MainActor () -> Void) {
        self.reasons = reasons
        self.isSignedIn = isSignedIn
        self.signIn = signIn
    }

    /// The offer that runs `palette.auth.signIn` in `registry` as the person's run.
    public init(registry: ActionRegistry, isSignedIn: @escaping @MainActor () -> Bool) {
        self.init(isSignedIn: isSignedIn) { [weak registry] in
            _ = registry?.perform("palette.auth.signIn", invocation: ActionInvocation(origin: .user))
        }
    }

    /// The refusal reasons that say to sign in to cmux before the action can run: every Cloud
    /// action's signed-out reason (``CloudStrings/signInFirst``) and its palette note.
    public static var signInReasons: Set<String> { [CloudStrings.signInFirst, CloudStrings.signInToContinue] }

    /// The Sign In a refusal with `reason` offers, or nil: the reason does not ask to sign in, or
    /// someone is signed in already (a stale reason must not start a second sign-in).
    public func offer(for reason: String) -> (@MainActor () -> Void)? {
        guard reasons.contains(reason), !isSignedIn() else { return nil }
        return signIn
    }
}
