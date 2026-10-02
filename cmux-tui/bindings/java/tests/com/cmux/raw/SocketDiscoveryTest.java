package com.cmux.raw;

import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

public final class SocketDiscoveryTest {
    public static void main(String[] args) {
        explicitWins();
        environmentOrderMatchesServer();
        runtimeFallbackMatchesServer();
        rejectsUnsafeSessionNames();
    }

    private static void explicitWins() {
        Path explicit = Path.of("/chosen/session.sock");
        Path result = SocketDiscovery.resolve(
            explicit,
            "main",
            Map.of("CMUX_TUI_SOCKET", "/ignored.sock"),
            "501"
        );
        check(result.equals(explicit), "explicit socket precedence");
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
        for (String value : new String[] {"", ".", "..", "a/b", "a\nb", "-bad", "x".repeat(65)}) {
            try {
                SocketDiscovery.validateSession(value);
                throw new AssertionError("accepted unsafe session " + value);
            } catch (IllegalArgumentException expected) {
                // expected
            }
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
