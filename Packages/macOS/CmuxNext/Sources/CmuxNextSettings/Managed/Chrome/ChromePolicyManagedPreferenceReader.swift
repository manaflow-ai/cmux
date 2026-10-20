public import Foundation

/// cmux's managed preferences with the organization's Chrome policies
/// beneath them (plans/cmux-next/chrome-enterprise-policy-DESIGN.md).
/// Precedence, highest first: cmux's own domain (`com.manaflow.cmux`),
/// cmux's browser policy domain (`com.manaflow.cmux.browser`, Chrome policy
/// names), Chrome's domain (`com.google.Chrome`), each forced above each
/// recommended as ``EffectiveSettings/merge(file:managed:team:)`` orders them.
/// A forced `HonorChromePolicy` = false in the browser domain drops Chrome's domain.
public nonisolated struct ChromePolicyManagedPreferenceReader: ManagedPreferenceReader {
    public let cmux: any ManagedPreferenceReader
    public let chrome: any ChromePolicyReading
    public let cmuxBrowser: any ChromePolicyReading

    /// - Parameters:
    ///   - cmux: cmux's own managed domain; its values always win.
    ///   - chrome: Google Chrome's policy domain.
    ///   - cmuxBrowser: cmux's browser policy domain, which wins over Chrome's key by key.
    public init(cmux: any ManagedPreferenceReader,
                chrome: any ChromePolicyReading = CFChromePolicyReader(),
                cmuxBrowser: any ChromePolicyReading = CFChromePolicyReader(domain: ChromePolicyDocument.cmuxDomain)) {
        self.cmux = cmux
        self.chrome = chrome
        self.cmuxBrowser = cmuxBrowser
    }

    /// The merged Chrome policies cmux applies (the browser domain over Chrome's).
    public func chromePolicies() -> ChromePolicyDocument {
        var own = cmuxBrowser.read()
        let honorChrome = own.mandatory.removeValue(forKey: ChromePolicyDocument.honorChromePolicyKey)?.boolValue != false
        own.recommended.removeValue(forKey: ChromePolicyDocument.honorChromePolicyKey)
        var base = honorChrome ? chrome.read() : .empty
        base.mandatory.removeValue(forKey: ChromePolicyDocument.honorChromePolicyKey)
        base.recommended.removeValue(forKey: ChromePolicyDocument.honorChromePolicyKey)
        return base.overlaid(by: own)
    }

    public func read() -> ManagedPreferences {
        cmux.read()  // red: Chrome policies not layered yet
    }
}
