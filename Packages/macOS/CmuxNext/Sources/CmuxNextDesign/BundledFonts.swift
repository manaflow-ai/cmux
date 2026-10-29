public import AppKit
import CoreText
import os

/// The UI font the app ships: Inter (`TypeScale.family`, Resources/Fonts, FONTS.md), the one UI face
/// of cmux NEXT, native and web (Leo 2026-10-21, ask-52da478628; pinned by
/// schemas/type-scale/leo-bans.json).
///
/// Native: the TTF is registered for this process on first use, then ``uiFont(size:weight:)`` makes
/// it at a size and weight (its `wght` axis set to the CSS weight). Chrome gets it through
/// `Typography.system` (`CheckedFont`); the text renderers add ``kern(for:)`` points of tracking.
///
/// Web: a WebContent process does not see this process's fonts, so every cmux web view installs
/// ``pageScript`` at document start after `WebTheme.bootstrapScript`: it declares the WOFF2 as the
/// `@font-face` that `--font-ui` names first, from a `data:` URL, which every page's CSP allows.
public nonisolated struct BundledFonts: Sendable {
    public init() {}

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "fonts")
    private static let resources = ModuleResourceBundle(cmuxNextTarget: "CmuxNextDesign", anchor: Anchor.self)
    private nonisolated final class Anchor {}

    /// The bundled file `name` (`InterVariable.ttf`), nil when the resource bundle or file is gone.
    static func file(_ name: String) -> URL? {
        let dot = name.lastIndex(of: ".") ?? name.endIndex
        let ext = dot < name.endIndex ? String(name[name.index(after: dot)...]) : nil
        let base = String(name[..<dot])
        // SwiftPM's `.process("Resources")` flattens Resources/Fonts into the bundle's root (as it
        // does Resources/BackdropArt); a build that keeps the folder has it under Fonts/.
        return resources.bundle?.url(forResource: base, withExtension: ext)
            ?? resources.bundle?.url(forResource: base, withExtension: ext, subdirectory: "Fonts")
    }

    /// Whether the UI font is a process font: the first read registers the TTF (or finds it
    /// registered). False when the file is missing or CoreText refused it; chrome then draws in
    /// the system font.
    public static let isRegistered: Bool = {
        guard let url = file(TypeScale.nativeFontFile) else {
            logger.error("bundled UI font \(TypeScale.nativeFontFile, privacy: .public) is missing")
            return false
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        let failure = error?.takeRetainedValue()
        // Registered before, or the person has Inter installed (a duplicate name): the family is there.
        if let failure, [CTFontManagerError.alreadyRegistered, .duplicatedName].map(\.rawValue).contains(CFErrorGetCode(failure)) {
            return true
        }
        logger.error("bundled UI font did not register: \(failure.map { "\($0)" } ?? "unknown", privacy: .public)")
        return false
    }()

    /// The UI font at `size` and `weight`; nil when it is not registered or AppKit matched another
    /// family (the caller falls back to the system font).
    public static func uiFont(size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        guard isRegistered else { return nil }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: TypeScale.fileFamily,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            .variation: [NSNumber(value: weightAxis): cssWeight(weight)],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size).flatMap(CheckedFont.nonNull),
              font.familyName == TypeScale.fileFamily
        else { return nil }
        return font
    }

    /// The tracking, in points, text in `font` gets (`.kern`): the UI font's em tracking at the
    /// font's size (`TypeScale.tracking(em:)`, the web's `--text-<step>--letter-spacing`), and 0 for
    /// any other face (system, monospaced, a person's chosen font).
    public static func kern(for font: NSFont?) -> CGFloat {
        guard let font, font.familyName == TypeScale.fileFamily else { return 0 }
        return TypeScale.tracking(em: font.pointSize) * font.pointSize
    }

    /// `text` with ``kern(for:)`` on every run in the UI font that sets no kern of its own.
    public static func tracked(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttributes(in: NSRange(location: 0, length: result.length)) { attributes, range, _ in
            guard attributes[.kern] == nil else { return }
            let amount = BundledFonts.kern(for: attributes[.font] as? NSFont)
            if amount != 0 { result.addAttribute(.kern, value: amount, range: range) }
        }
        return result
    }

    /// The `wght` variation axis tag.
    private static let weightAxis: UInt32 = 0x7767_6874
    /// AppKit's named weights and the CSS weights they are.
    private static let cssWeights: [(appKit: CGFloat, css: Double)] = [
        (NSFont.Weight.ultraLight.rawValue, 100), (NSFont.Weight.thin.rawValue, 200), (NSFont.Weight.light.rawValue, 300),
        (NSFont.Weight.regular.rawValue, 400), (NSFont.Weight.medium.rawValue, 500), (NSFont.Weight.semibold.rawValue, 600),
        (NSFont.Weight.bold.rawValue, 700), (NSFont.Weight.heavy.rawValue, 800), (NSFont.Weight.black.rawValue, 900),
    ]

    /// The CSS weight of `weight`: linear between AppKit's named weights, clamped to 100...900.
    static func cssWeight(_ weight: NSFont.Weight) -> Double {
        let value = weight.rawValue
        guard let first = cssWeights.first, let last = cssWeights.last else { return 400 }
        if value <= first.appKit { return first.css }
        for (low, high) in zip(cssWeights, cssWeights.dropFirst()) where value <= high.appKit {
            return low.css + (high.css - low.css) * Double((value - low.appKit) / (high.appKit - low.appKit))
        }
        return last.css
    }

    /// The document-start script that declares the UI font's `@font-face` (the WOFF2 as a `data:`
    /// URL, weights 100 to 900) in a `<style id="cmux-ui-font">`; empty when the file is missing.
    /// Made once per process; ``prepareInBackground()`` makes it off the main thread at launch.
    public static let pageScript: String = {
        // concurrency-allow: once per process, and prepareInBackground() reads it off the main thread at launch
        guard let url = file(TypeScale.webFontFile), let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            logger.error("bundled UI font \(TypeScale.webFontFile, privacy: .public) is missing; pages use the system font")
            return ""
        }
        let rule = "@font-face{font-family:\"\(TypeScale.family)\";src:url(data:font/woff2;base64,\(data.base64EncodedString())) "
            + "format(\"woff2\");font-weight:100 900;font-style:normal;font-display:block}"
        return """
        (function () {
          function install() {
            if (document.getElementById('cmux-ui-font')) return;
            var style = document.createElement('style');
            style.id = 'cmux-ui-font';
            style.textContent = '\(rule)';
            (document.head || document.documentElement).appendChild(style);
          }
          if (document.documentElement) { install(); return; }
          // Chromium runs new-document scripts before the parser makes <html>: install once it does.
          if (!window.MutationObserver) return;
          var rootWatch = new MutationObserver(function () {
            if (!document.documentElement) return;
            rootWatch.disconnect();
            install();
          });
          rootWatch.observe(document, { childList: true });
        })();
        """
    }()

    /// Registers the UI font and makes ``pageScript`` off the main thread: called once at launch, so
    /// neither happens on the main thread when the first chrome text draws or the first page opens.
    public static func prepareInBackground() {
        // task-owner: one font registration and one 352 KB read per process; nothing waits for it
        Task.detached(priority: .userInitiated) {
            _ = BundledFonts.isRegistered
            _ = BundledFonts.pageScript
        }
    }
}
