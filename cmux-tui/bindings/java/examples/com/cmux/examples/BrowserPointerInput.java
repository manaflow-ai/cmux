package com.cmux.examples;

import com.cmux.Browser;
import com.cmux.BrowserAttachmentItem;
import com.cmux.Decimal;
import com.cmux.EmptyResult;
import com.cmux.MutationResult;
import com.cmux.Options;
import java.util.Map;

/** Threads a presented browser frame's exact token into pointer input. */
public final class BrowserPointerInput {
    private BrowserPointerInput() {}

    public static MutationResult<EmptyResult> moveAfterPresenting(
        Browser browser,
        BrowserAttachmentItem.Frame presentedFrame,
        double xPx,
        double yPx
    ) {
        Decimal token = pointerToken(presentedFrame);
        return browser.mouse(new Options.BrowserMouse(
            Options.Mutation.defaults(),
            Map.of(
                "kind", "move",
                "x_px", xPx,
                "y_px", yPx
            ),
            token
        ));
    }

    public static MutationResult<EmptyResult> wheelAfterPresenting(
        Browser browser,
        BrowserAttachmentItem.Frame presentedFrame,
        double deltaX,
        double deltaY,
        double xPx,
        double yPx
    ) {
        return browser.wheel(new Options.Wheel(
            Options.Mutation.defaults(),
            deltaX,
            deltaY,
            xPx,
            yPx,
            pointerToken(presentedFrame)
        ));
    }

    private static Decimal pointerToken(
        BrowserAttachmentItem.Frame presentedFrame
    ) {
        return presentedFrame.pointerFrameSeq().orElseThrow(
            () -> new IllegalStateException(
                "the presented browser frame does not authorize pointer input"
            )
        );
    }
}
