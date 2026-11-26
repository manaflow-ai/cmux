package com.cmux.raw;

import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.channels.ServerSocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

public final class SocketDiscoveryTest {
    public static void main(String[] args) {
        explicitWins();
        environmentOrderMatchesServer();
        runtimeFallbackMatchesServer();
        rejectsUnsafeSessionNames();
        preservesLegacySafeSessionNames();
        longSessionUsesBindableDigestFallback();
        hashedSessionFallsBackToTmpWhenRuntimeBaseIsTooLong();
        nonAsciiLongSessionUsesSharedUtf8Sha256Digest();
        overlongLegacyFallbackIsSuppressed();
    }

    private static void explicitWins() {
        Path explicit = Path.of("/chosen/session.sock");
        Path result = SocketDiscovery.resolve(
            explicit,
            "../unsafe",
            Map.of("CMUX_TUI_SOCKET", "/ignored.sock"),
            "501"
        );
        check(result.equals(explicit), "explicit socket precedence");

        check(
            SocketDiscovery.resolve(
                null,
                "../unsafe",
                Map.of("CMUX_TUI_SOCKET", "/inherited.sock"),
                "501"
            ).equals(Path.of("/inherited.sock")),
            "inherited socket bypasses derived session validation"
        );
    }

    private static void environmentOrderMatchesServer() {
        HashMap<String, String> env = new HashMap<>();
        env.put("CMUX_TUI_SOCKET", "/new.sock");
        env.put("CMUX_MUX_SOCKET", "/legacy.sock");
        env.put("XDG_RUNTIME_DIR", "/run/user/501");
        check(
            SocketDiscovery.resolve(null, "main", env, "501").equals(Path.of("/new.sock")),
            "CMUX_TUI_SOCKET precedence"
        );
        env.remove("CMUX_TUI_SOCKET");
        check(
            SocketDiscovery.resolve(null, "main", env, "501").equals(Path.of("/legacy.sock")),
            "legacy inherited socket"
        );
        env.put("CMUX_TUI_SOCKET", "   ");
        check(
            SocketDiscovery.resolve(null, "main", env, "501").equals(Path.of("   ")),
            "whitespace socket value is preserved"
        );
        env.remove("CMUX_TUI_SOCKET");
        env.remove("CMUX_MUX_SOCKET");
        check(
            SocketDiscovery.resolve(null, "main", env, "501")
                .equals(Path.of("/run/user/501/cmux-tui-501/main.sock")),
            "XDG runtime root"
        );
        env.remove("XDG_RUNTIME_DIR");
        env.put("TMPDIR", "/private/tmp");
        check(
            SocketDiscovery.resolve(null, "main", env, "501")
                .equals(Path.of("/private/tmp/cmux-tui-501/main.sock")),
            "TMPDIR runtime root"
        );
    }

    private static void runtimeFallbackMatchesServer() {
        String root = "/tmp/" + "x".repeat(200);
        Path resolved = SocketDiscovery.resolve(
            null,
            "sdk",
            Map.of("XDG_RUNTIME_DIR", root),
            "501"
        );
        check(
            resolved.equals(Path.of("/tmp/cmux-tui-501/sdk.sock")),
            "short /tmp fallback"
        );
        check(SocketDiscovery.fitsUnixSocket(resolved), "fallback fits sockaddr_un");
    }

    private static void rejectsUnsafeSessionNames() {
        for (String value : new String[] {
            "", ".", "..", "a/b", "a/../b", "a\\b", "a\nb", "a\u0000b", "a\u0085b",
            "a\u2028b", "a\u2029b", "\uD800"
        }) {
            try {
                SocketDiscovery.validateSession(value);
                throw new AssertionError("accepted unsafe session " + value);
            } catch (IllegalArgumentException expected) {
                // expected
            }
        }
    }

    private static void preservesLegacySafeSessionNames() {
        Map<String, String> environment = Map.of("XDG_RUNTIME_DIR", "/run/user/501");
        for (String value : new String[] {
            "contains space", "名前", "_leading", "-leading", ".leading",
            "legacy:colon"
        }) {
            SocketDiscovery.validateSession(value);
            Path resolved = SocketDiscovery.resolve(null, value, environment, "501");
            check(
                resolved.toString().endsWith("/" + value + ".sock"),
                "legacy-safe session path " + value
            );
        }
    }

    private static void longSessionUsesBindableDigestFallback() {
        String session = "legacy-" + "x".repeat(200);
        Path resolved = SocketDiscovery.resolve(
            null,
            session,
            Map.of("XDG_RUNTIME_DIR", "/run/u/501"),
            "501"
        );
        Path expected = Path.of(
            "/run/u/501",
            "cmux-tui-hashed-501",
            "e538a84493067947f7376110a6f695dd3"
                + "db062b67eee939c3660c07f3f47dce2.sock"
        );
        check(resolved.equals(expected), "shared long-session digest path");
        check(SocketDiscovery.fitsUnixSocket(resolved), "long-session path fits sockaddr_un");

        try {
            Path directory = Files.createTempDirectory("cmux-java-long-");
            Path bindPath = null;
            try {
                int leafLength = utf8Length(resolved) - utf8Length(directory) - 1;
                check(leafLength > ".sock".length(), "temporary bind leaf is too short");
                bindPath = directory.resolve(
                    "x".repeat(leafLength - ".sock".length()) + ".sock"
                );
                check(
                    utf8Length(bindPath) == utf8Length(resolved),
                    "temporary bind path must preserve the canonical byte length"
                );
                try (ServerSocketChannel server = ServerSocketChannel.open(StandardProtocolFamily.UNIX)) {
                    server.bind(UnixDomainSocketAddress.of(bindPath));
                }
            } finally {
                if (bindPath != null) {
                    Files.deleteIfExists(bindPath);
                }
                Files.deleteIfExists(directory);
            }
        } catch (IOException error) {
            throw new AssertionError("long-session path is not bindable: " + resolved, error);
        }
    }

    private static void hashedSessionFallsBackToTmpWhenRuntimeBaseIsTooLong() {
        String session = "legacy-" + "x".repeat(200);
        Path resolved = SocketDiscovery.resolve(
            null,
            session,
            Map.of("XDG_RUNTIME_DIR", "/tmp/" + "x".repeat(200)),
            "501"
        );
        check(
            resolved.getParent().equals(Path.of("/tmp", "cmux-tui-hashed-501")),
            "long runtime hash falls back to /tmp"
        );
    }

    private static void nonAsciiLongSessionUsesSharedUtf8Sha256Digest() {
        String session = "\u540D\u524D".repeat(100);
        Path resolved = SocketDiscovery.resolve(
            null,
            session,
            Map.of("XDG_RUNTIME_DIR", "/run/u/501"),
            "501"
        );
        Path expected = Path.of(
            "/run/u/501",
            "cmux-tui-hashed-501",
            "0d3fd777d54547652e50e049becfce29b81513bc248da9d22bbd37593f0d52e3.sock"
        );
        check(resolved.equals(expected), "shared non-ASCII UTF-8 digest path");
    }

    private static void overlongLegacyFallbackIsSuppressed() {
        String session = "legacy-" + "x".repeat(200);
        String uid = SocketDiscovery.currentUid();
        Path hashed = Path.of(
            "/tmp", "cmux-tui-hashed-" + uid,
            "e538a84493067947f7376110a6f695dd3"
                + "db062b67eee939c3660c07f3f47dce2.sock"
        );
        Path raw = Path.of("/tmp", "cmux-tui-" + uid, session + ".sock");
        check(!SocketDiscovery.fitsUnixSocket(raw), "test session must exceed Unix socket limit");
        check(SocketDiscovery.legacyRawFallback(hashed, session) == null,
            "overlong legacy fallback is suppressed");
    }

    private static int utf8Length(Path path) {
        return path.toString().getBytes(StandardCharsets.UTF_8).length;
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
