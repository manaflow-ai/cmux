package com.cmux.consumer;

import com.cmux.CmuxClient;
import com.cmux.RenderText;
import com.cmux.UInt64;
import com.cmux.WorkspaceLease;
import com.cmux.generated.CreateWorkspaceRequest;
import com.cmux.generated.RenderRow;
import com.cmux.generated.RenderRun;
import java.util.List;

public final class ExternalJarConsumerTest {
    private ExternalJarConsumerTest() {}

    public static void main(String[] args) throws ReflectiveOperationException {
        RenderRun run = RenderRun.builder()
            .attrs(0)
            .bg(null)
            .fg(null)
            .text("jar consumer")
            .build();
        RenderRow row = RenderRow.builder().row(0).runs(List.of(run)).build();
        require("jar consumer".equals(RenderText.plainText(row)), "render helper from jar");
        require(
            CmuxClient.MAX_SCROLLBACK_PAGE_ROWS == 65_535,
            "scrollback page bound from jar"
        );
        CmuxClient.class.getMethod("readScrollbackTail", UInt64.class, int.class);
        CmuxClient.class.getMethod(
            "createWorkspaceLease",
            CreateWorkspaceRequest.class
        );
        require(
            AutoCloseable.class.isAssignableFrom(WorkspaceLease.class),
            "workspace lease is closeable"
        );
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
