import { NextRequest, NextResponse } from "next/server";
import { stackServerApp } from "@/lib/utils/stack";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * POST /api/preview/checkout
 *
 * Creates a Stripe checkout URL for the preview subscription at the team level.
 * Requires authenticated user who is a member of the specified team.
 *
 * Request body:
 * - productId: string - The Stack Auth product ID (e.g., "preview-pro")
 * - teamSlugOrId: string - The team to associate the subscription with (required)
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

    if (!teamSlugOrId) {
      return NextResponse.json(
        { error: "teamSlugOrId is required" },
        { status: 400 }
      );
    }

    // Get user's teams and find the specified team
    const teams = await user.listTeams();
    const team = teams.find(
      (t) => t.id === teamSlugOrId || (t as { slug?: string }).slug === teamSlugOrId
    );

    if (!team) {
      return NextResponse.json(
        { error: "Team not found or user is not a member" },
        { status: 404 }
      );
    }

    console.log("[preview/checkout] Creating team checkout URL", {
      userId: user.id,
      teamId: team.id,
      productId,
      teamSlugOrId,
    });

    // Create checkout URL at the team level using Stack Auth's payment integration
    // Reference: Stack Auth docs - team.createCheckoutUrl() attaches subscription to team
    const checkoutUrl = await team.createCheckoutUrl({
      productId,
    });

    console.log("[preview/checkout] Team checkout URL created successfully", {
      userId: user.id,
      teamId: team.id,
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
