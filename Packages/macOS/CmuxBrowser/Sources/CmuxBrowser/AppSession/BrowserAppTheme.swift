public import Foundation

/// Serializable app-web theme values shared by pricing and Pro welcome browser surfaces.
public struct BrowserAppTheme: Equatable, Sendable {
    public let appearance: String
    public let background: String
    public let foreground: String
    public let accent: String
    public let accentOnBackground: String
    public let accentOnForeground: String

    /// Creates a complete theme after the app has resolved readable accent variants.
    public init(
        appearance: String,
        background: String,
        foreground: String,
        accent: String,
        accentOnBackground: String,
        accentOnForeground: String
    ) {
        self.appearance = appearance
        self.background = background
        self.foreground = foreground
        self.accent = accent
        self.accentOnBackground = accentOnBackground
        self.accentOnForeground = accentOnForeground
    }

    /// Query items used to seed a server-rendered app-web page with the native theme.
    public var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "appearance", value: appearance),
            URLQueryItem(name: "background", value: background),
            URLQueryItem(name: "foreground", value: foreground),
            URLQueryItem(name: "accent", value: accent),
            URLQueryItem(name: "accent_on_background", value: accentOnBackground),
            URLQueryItem(name: "accent_on_foreground", value: accentOnForeground),
        ]
    }

    /// JavaScript that refreshes an already-rendered supported page without navigation.
    public func applyingJavaScript() -> String? {
        let payload = JavaScriptPayload(
            appearance: appearance,
            background: background,
            foreground: foreground,
            accent: accent,
            accentOnBackground: accentOnBackground,
            accentOnForeground: accentOnForeground
        )
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return """
        (() => {
          const root = document.querySelector('[data-cmux-app-theme]');
          if (!root) return false;
          const theme = \(json);
          root.style.setProperty('--ghostty-background', theme.background);
          root.style.setProperty('--ghostty-foreground', theme.foreground);
          root.style.setProperty('--cmux-product-blue', theme.accent);
          root.style.setProperty('--cmux-product-blue-on-background', theme.accentOnBackground);
          root.style.setProperty('--cmux-product-blue-on-foreground', theme.accentOnForeground);
          root.style.backgroundColor = theme.background;
          root.style.colorScheme = theme.appearance;
          root.dataset.cmuxAppThemeAppearance = theme.appearance;
          if (root.hasAttribute('data-app-pricing-appearance')) {
            root.setAttribute('data-app-pricing-appearance', theme.appearance);
          }
          if (root.hasAttribute('data-app-pro-welcome-appearance')) {
            root.setAttribute('data-app-pro-welcome-appearance', theme.appearance);
          }
          for (const element of [document.documentElement, document.body]) {
            element?.style.setProperty('background', theme.background, 'important');
          }
          document.querySelector('meta[name="theme-color"]')
            ?.setAttribute('content', theme.background);
          return true;
        })()
        """
    }

    /// Checks the app-web URL contract without constructing theme colors.
    public static func supportsAppSurface(url: URL?, trustedOrigin: URL) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              BrowserAppWebOrigin(trustedOrigin).containsAppSurface(url) else {
            return false
        }
        return true
    }

    private struct JavaScriptPayload: Encodable {
        let appearance: String
        let background: String
        let foreground: String
        let accent: String
        let accentOnBackground: String
        let accentOnForeground: String
    }
}
