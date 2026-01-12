import { fetchLatestRelease } from "@/lib/fetch-latest-release";

export async function GET() {
  try {
    const release = await fetchLatestRelease();
    return Response.json(release);
  } catch (error) {
    console.error("Failed to fetch latest release:", error);
    return Response.json({
      fallbackUrl: "",
      latestVersion: "",
      macDownloadUrls: {},
    });
  }
}