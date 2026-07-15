/// A WebKit cookie could not be represented as an `HTTPCookie`.
enum WebKitBrowserEngineCookieError: Error {
    case invalidPayload
}
