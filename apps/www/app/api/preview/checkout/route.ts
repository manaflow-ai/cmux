import { NextRequest, NextResponse } from "next/server";
import { stackServerApp } from "@/lib/utils/stack";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * POST /api/preview/checkout
 *
 * Creates a Stripe checkout URL for the preview subscription.
 * Requires authenticated user.
 *
 * Request body:
 * - productId: string - The Stack Auth product ID (e.g., "preview-pro")
 * - teamSlugOrId: string - The team to associate the subscription with (for future use)
 *
 * Response:
 * - checkoutUrl: string - The Stripe checkout URL to redirect to
 */
export async function POST(request: NextRequest) {
  try {
    const user = await stackServerApp.getUser();

    if (!user) {
      return NextResponse.json(
        { error: "Authentication required" },
        { status: 401 }
      );
    }

    let body: { productId?: string; teamSlugOrId?: string };
    try {
      body = await request.json();
    } catch {
      return NextResponse.json(
        { error: "Invalid JSON body" },
        { status: 400 }
      );
    }

    const { productId, teamSlugOrId } = body;

    if (!productId) {
      return NextResponse.json(
        { error: "productId is required" },
        { status: 400 }
      );
    }

    console.log("[preview/checkout] Creating checkout URL", {
      userId: user.id,
      productId,
      teamSlugOrId,
    });

    // Create checkout URL using Stack Auth's payment integration
    // The productId should be configured in the Stack Auth dashboard
    const checkoutUrl = await user.createCheckoutUrl({
      productId,
    });

    console.log("[preview/checkout] Checkout URL created successfully", {
      userId: user.id,
      productId,
    });

    return NextResponse.json({ checkoutUrl });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    console.error("[preview/checkout] Failed to create checkout URL", {
      error,
      message,
    });

    return NextResponse.json(
      { error: message },
      { status: 500 }
    );
  }
}
