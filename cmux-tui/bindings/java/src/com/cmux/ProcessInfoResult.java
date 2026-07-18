package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public record ProcessInfoResult(Long pid, List<String> command, String cwd, String tty) {
    static ProcessInfoResult from(Map<String, Object> data) {
        Long pid = data.get("pid") instanceof Number value ? value.longValue() : null;
        List<String> command = null;
        Object rawCommand = data.get("command");
        if (rawCommand != null) {
            if (!(rawCommand instanceof List<?> arguments)) {
                throw new IllegalArgumentException("process-info command must be an argv array or null");
            }
            ArrayList<String> decoded = new ArrayList<>(arguments.size());
            for (Object argument : arguments) {
                if (!(argument instanceof String value)) {
                    throw new IllegalArgumentException("process-info argv entries must be strings");
                }
                decoded.add(value);
            }
            command = List.copyOf(decoded);
        }
        return new ProcessInfoResult(
            pid,
            command,
            optionalString(data.get("cwd"), "cwd"),
            optionalString(data.get("tty"), "tty")
        );
    }

    private static String optionalString(Object value, String field) {
        if (value == null) {
            return null;
        }
        if (value instanceof String string) {
            return string;
        }
        throw new IllegalArgumentException("process-info " + field + " must be a string or null");
    }
}
