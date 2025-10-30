import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";
import { env } from "@/lib/utils/www-env";

export function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // Check if this is a PR review page that requires authentication
  const isPRReviewPage =
    /^\/[^/]+\/[^/]+\/pull\/\d+$/.test(pathname) ||
    /^\/[^/]+\/[^/]+\/compare\//.test(pathname);

  // Skip auth check for the auth page itself
  if (pathname.endsWith("/auth")) {
    return NextResponse.next();
  }

  // Skip auth check for API routes
  if (pathname.startsWith("/api/")) {
    return NextResponse.next();
  }

  // Only check cookies for PR review pages
  if (!isPRReviewPage) {
    return NextResponse.next();
  }

  // Check for Stack Auth cookies
  const stackAccessCookie = request.cookies.get("stack-access");
  const stackRefreshCookie = request.cookies.get(
    `stack-refresh-${env.NEXT_PUBLIC_STACK_PROJECT_ID}`
  );

  const hasStackAuthCookies = !!(stackAccessCookie || stackRefreshCookie);

  console.log("[middleware] Checking cookies for:", pathname);
  console.log("[middleware] Has stack-access:", !!stackAccessCookie);
  console.log("[middleware] Has stack-refresh:", !!stackRefreshCookie);
  console.log("[middleware] hasStackAuthCookies:", hasStackAuthCookies);

  // If no cookies, redirect to auth page
  if (!hasStackAuthCookies) {
    console.log("[middleware] No Stack Auth cookies found, redirecting to auth page");
    const url = request.nextUrl.clone();
    url.pathname = `${pathname}/auth`;
    return NextResponse.redirect(url);
  }

  // Cookies exist, allow the request to proceed
  return NextResponse.next();
}

export const config = {
  matcher: [
    /*
     * Match all PR review and comparison pages:
     * - /:owner/:repo/pull/:number
     * - /:owner/:repo/compare/...
     * But exclude:
     * - /api routes
     * - /_next (Next.js internals)
     * - Static files
     */
    "/:owner/:repo/pull/:number",
    "/:owner/:repo/compare/:path*",
    /*
     * Match all request paths except for the ones starting with:
     * - api (API routes)
     * - _next/static (static files)
     * - _next/image (image optimization files)
     * - favicon.ico (favicon file)
     */
    "/((?!api|_next/static|_next/image|favicon.ico).*)",
  ],
};
