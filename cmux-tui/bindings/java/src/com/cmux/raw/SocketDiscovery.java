package com.cmux.raw;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Map;
import java.util.Objects;

/** Normative Unix socket discovery shared by the client and tests. */
public final class SocketDiscovery {
    private SocketDiscovery() {}

    public static Path resolve(Path explicitSocket, String session) {
        return resolve(explicitSocket, session, System.getenv(), currentUid());
    }

    static Path resolve(
        Path explicitSocket,
        String session,
        Map<String, String> environment,
        String uid
    ) {
        if (explicitSocket != null) {
            return explicitSocket;
        }
        String inherited = nonBlank(environment.get("CMUX_TUI_SOCKET"));
        if (inherited == null) {
            inherited = nonBlank(environment.get("CMUX_MUX_SOCKET"));
        }
        if (inherited != null) {
            return Path.of(inherited);
        }
        validateSession(session);
        String root = nonBlank(environment.get("XDG_RUNTIME_DIR"));
        if (root == null) {
            root = nonBlank(environment.get("TMPDIR"));
        }
        if (root == null) {
            root = "/tmp";
        }
        String fileName = session + ".sock";
        Path preferred = Path.of(root, "cmux-tui-" + uid, fileName);
        if (fitsUnixSocket(preferred)) {
            return preferred;
        }
        Path fallback = Path.of("/tmp", "cmux-tui-" + uid, fileName);
        if (fitsUnixSocket(fallback)) {
            return fallback;
        }
        String digest = sessionDigest(session) + ".sock";
        Path hashed = Path.of(root, "cmux-tui-hashed-" + uid, digest);
        if (fitsUnixSocket(hashed)) {
            return hashed;
        }
        return Path.of("/tmp", "cmux-tui-hashed-" + uid, digest);
    }

    public static Path defaultSocketPath(String session) {
        return resolve(null, session);
    }

    /** Compatibility path for servers that still publish a raw short-session socket. */
    public static Path legacyRawFallback(Path resolved, String session) {
        if (nonBlank(System.getenv("CMUX_TUI_SOCKET")) != null
                || nonBlank(System.getenv("CMUX_MUX_SOCKET")) != null) return null;
        validateSession(session);
        String uid = currentUid();
        String root = nonBlank(System.getenv("XDG_RUNTIME_DIR"));
        if (root == null) root = nonBlank(System.getenv("TMPDIR"));
        if (root == null) root = "/tmp";
        Path hashed = Path.of(root, "cmux-tui-hashed-" + uid, sessionDigest(session) + ".sock");
        Path hashedTmp = Path.of("/tmp", "cmux-tui-hashed-" + uid, sessionDigest(session) + ".sock");
        if (!resolved.equals(hashed) && !resolved.equals(hashedTmp)) return null;
        Path fallback = Path.of("/tmp", "cmux-tui-" + uid, session + ".sock");
        return fitsUnixSocket(fallback) ? fallback : null;
    }

    public static void validateSession(String session) {
        Objects.requireNonNull(session, "session");
        if (session.isEmpty() || session.equals(".") || session.equals("..")) {
            throw invalidSession();
        }
        for (int offset = 0; offset < session.length();) {
            int codePoint = session.codePointAt(offset);
            offset += Character.charCount(codePoint);
            if (codePoint == '/' || codePoint == '\\' || codePoint == 0
                    || Character.isISOControl(codePoint)
                    || codePoint == 0x0085
                    || codePoint == 0x2028
                    || codePoint == 0x2029
                    || (codePoint >= Character.MIN_SURROGATE
                        && codePoint <= Character.MAX_SURROGATE)) {
                throw invalidSession();
            }
        }
    }

    private static IllegalArgumentException invalidSession() {
        return new IllegalArgumentException(
            "session name must be a non-empty path component "
                + "without separators or control characters"
        );
    }

    private static String sessionDigest(String session) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                .digest(session.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException error) {
            throw new IllegalStateException("SHA-256 is unavailable", error);
        }
    }

    static boolean fitsUnixSocket(Path path) {
        int capacity = System.getProperty("os.name", "")
            .toLowerCase()
            .contains("mac") ? 104 : 108;
        return path.toString().getBytes(StandardCharsets.UTF_8).length < capacity;
    }

    static String currentUid() {
        Path probe = null;
        try {
            probe = Files.createTempFile("cmux-tui-java-uid", ".tmp");
            Object uid = Files.getAttribute(probe, "unix:uid");
            return String.valueOf(uid);
        } catch (IOException | UnsupportedOperationException error) {
            String uid = nonBlank(System.getenv("UID"));
            return uid != null ? uid : System.getProperty("user.name", "0");
        } finally {
            if (probe != null) {
                try {
                    Files.deleteIfExists(probe);
                } catch (IOException ignored) {
                    // best effort
                }
            }
        }
    }

    private static String nonBlank(String value) {
        // Match Go, C++, Python, and Zig discovery: only an unset or empty
        // variable is absent. Whitespace can be a deliberate socket path.
        return value == null || value.isEmpty() ? null : value;
    }
}
