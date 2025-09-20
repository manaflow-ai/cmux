import { Button } from "@/components/ui/button";
import { api } from "@cmux/convex/api";
import { useUser, type Team } from "@stackframe/react";
import * as Dialog from "@radix-ui/react-dialog";
import { useMutation } from "convex/react";
import { X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";

type Step = "details" | "invites";

interface CreateTeamDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: (result: { team: Team; slug: string; teamSlugOrId: string }) => void;
}

interface FieldErrors {
  displayName?: string;
  slug?: string;
}

export function CreateTeamDialog({ open, onOpenChange, onCreated }: CreateTeamDialogProps) {
  const user = useUser({ or: "return-null" });
  const upsertTeamPublic = useMutation(api.stack.upsertTeamPublic);
  const ensureMembershipPublic = useMutation(api.stack.ensureMembershipPublic);
  const setTeamSlug = useMutation(api.teams.setSlug);

  const [step, setStep] = useState<Step>("details");
  const [displayName, setDisplayName] = useState("");
  const [slugInput, setSlugInput] = useState("");
  const [slugManuallyEdited, setSlugManuallyEdited] = useState(false);
  const [inviteInput, setInviteInput] = useState("");
  const [fieldErrors, setFieldErrors] = useState<FieldErrors>({});
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [createdTeam, setCreatedTeam] = useState<Team | null>(null);
  const [cachedMetadata, setCachedMetadata] = useState<Record<string, unknown>>({});
  const [hasEnsuredMembership, setHasEnsuredMembership] = useState(false);
  const [invitesSent, setInvitesSent] = useState(false);

  useEffect(() => {
    if (!slugManuallyEdited) {
      setSlugInput(slugify(displayName));
    }
  }, [displayName, slugManuallyEdited]);

  const handleDialogOpenChange = (nextOpen: boolean) => {
    if (!nextOpen) {
      resetState();
    }
    onOpenChange(nextOpen);
  };

  const resetState = () => {
    setStep("details");
    setDisplayName("");
    setSlugInput("");
    setSlugManuallyEdited(false);
    setInviteInput("");
    setFieldErrors({});
    setError(null);
    setLoading(false);
    setCreatedTeam(null);
    setCachedMetadata({});
    setHasEnsuredMembership(false);
    setInvitesSent(false);
  };

  const handleDetailsSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const trimmedName = displayName.trim();
    const normalizedSlug = normalizeSlug(slugInput);

    const errors: FieldErrors = {};
    if (trimmedName.length < 1 || trimmedName.length > 32) {
      errors.displayName = "Name must be 1–32 characters long";
    }
    const slugError = validateSlug(normalizedSlug);
    if (slugError) {
      errors.slug = slugError;
    }

    if (Object.keys(errors).length > 0) {
      setFieldErrors(errors);
      return;
    }

    setFieldErrors({});
    setError(null);
    setStep("invites");
  };

  const handleBack = () => {
    setStep("details");
    setError(null);
  };

  const handleCreateTeam = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!user) {
      setError("You need to be signed in to create a team.");
      return;
    }

    const trimmedName = displayName.trim();
    const normalizedSlug = normalizeSlug(slugInput);
    const slugError = validateSlug(normalizedSlug);
    if (slugError) {
      setFieldErrors((prev) => ({ ...prev, slug: slugError }));
      setStep("details");
      return;
    }

    setLoading(true);
    setError(null);

    try {
      let team = createdTeam;
      if (!team) {
        team = await user.createTeam({ displayName: trimmedName });
        setCreatedTeam(team);
        const metadata = extractMetadata(team.clientMetadata);
        setCachedMetadata(metadata);
      } else if (team.displayName !== trimmedName) {
        await team.update({ displayName: trimmedName });
      }

      if (!team) {
        throw new Error("Failed to create team. Please try again.");
      }

      if (!hasEnsuredMembership) {
        await ensureMembershipPublic({ teamId: team.id, userId: user.id });
        setHasEnsuredMembership(true);
      }

      const { slug } = await setTeamSlug({ teamSlugOrId: team.id, slug: normalizedSlug });
      const metadata = { ...cachedMetadata, slug };
      await team.update({ displayName: trimmedName, clientMetadata: metadata });
      setCachedMetadata(metadata);

      await upsertTeamPublic({
        id: team.id,
        displayName: trimmedName,
        profileImageUrl: team.profileImageUrl ?? undefined,
        clientMetadata: metadata,
        clientReadOnlyMetadata: team.clientReadOnlyMetadata ?? undefined,
        createdAtMillis: Date.now(),
      });

      if (!invitesSent) {
        const emails = parseInviteEmails(inviteInput);
        if (emails.length > 0) {
          for (const email of emails) {
            try {
              await team.inviteUser({ email });
            } catch (inviteError) {
              console.error("Failed to invite", email, inviteError);
            }
          }
        }
        setInvitesSent(true);
      }

      const teamSlugOrId = slug || team.id;
      onCreated?.({ team, slug, teamSlugOrId });
      handleDialogOpenChange(false);
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to create team. Please try again.";
      setError(message);
      if (message.toLowerCase().includes("slug")) {
        setFieldErrors((prev) => ({ ...prev, slug: message }));
        setStep("details");
      }
    } finally {
      setLoading(false);
    }
  };

  const slugPreview = useMemo(() => {
    const normalized = normalizeSlug(slugInput);
    return normalized.length > 0 ? normalized : "your-team";
  }, [slugInput]);

  return (
    <Dialog.Root open={open} onOpenChange={handleDialogOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-[var(--z-modal)] bg-neutral-950/60 backdrop-blur-sm" />
        <Dialog.Content
          className="fixed left-1/2 top-1/2 z-[calc(var(--z-modal)+1)] w-full max-w-xl -translate-x-1/2 -translate-y-1/2 rounded-xl border border-neutral-200 bg-white p-6 shadow-xl outline-none dark:border-neutral-800 dark:bg-neutral-900"
          onEscapeKeyDown={(event) => {
            if (loading) {
              event.preventDefault();
            }
          }}
          onInteractOutside={(event) => {
            if (loading) {
              event.preventDefault();
            }
          }}
        >
          <div className="flex items-start justify-between gap-4">
            <div>
              <Dialog.Title className="text-xl font-semibold text-neutral-900 dark:text-neutral-50">
                Create a team
              </Dialog.Title>
              <Dialog.Description className="mt-1 text-sm text-neutral-600 dark:text-neutral-400">
                Choose a name, pick a slug, and invite teammates to get started.
              </Dialog.Description>
            </div>
            <Dialog.Close asChild>
              <Button
                type="button"
                variant="ghost"
                size="icon"
                className="text-neutral-500 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-100"
                disabled={loading}
              >
                <X className="size-4" aria-hidden="true" />
                <span className="sr-only">Close</span>
              </Button>
            </Dialog.Close>
          </div>

          <div className="mt-4 text-sm font-medium text-neutral-700 dark:text-neutral-300">
            Step {step === "details" ? "1" : "2"} of 2
          </div>

          {step === "details" ? (
            <form onSubmit={handleDetailsSubmit} className="mt-6 space-y-6">
              <div className="space-y-2">
                <label className="block text-sm font-medium text-neutral-800 dark:text-neutral-200">
                  Team name
                </label>
                <input
                  value={displayName}
                  onChange={(event) => {
                    setDisplayName(event.target.value);
                  }}
                  placeholder="e.g. cmux maintainers"
                  className="w-full rounded-lg border border-neutral-300 bg-white px-3 py-2 text-sm text-neutral-900 shadow-xs outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/40 dark:border-neutral-700 dark:bg-neutral-950 dark:text-neutral-100"
                  autoFocus
                />
                {fieldErrors.displayName ? (
                  <p className="text-sm text-red-500 dark:text-red-400">{fieldErrors.displayName}</p>
                ) : (
                  <p className="text-sm text-neutral-600 dark:text-neutral-400">
                    This is how your team will appear to members.
                  </p>
                )}
              </div>

              <div className="space-y-2">
                <label className="block text-sm font-medium text-neutral-800 dark:text-neutral-200">
                  Team slug
                </label>
                <div className="flex items-center gap-2">
                  <span className="text-sm text-neutral-500 dark:text-neutral-400">cmux.app/</span>
                  <input
                    value={slugInput}
                    onChange={(event) => {
                      setSlugManuallyEdited(true);
                      const sanitized = sanitizeSlugInput(event.target.value);
                      setSlugInput(sanitized);
                    }}
                    placeholder="your-team"
                    className="w-full rounded-lg border border-neutral-300 bg-white px-3 py-2 text-sm text-neutral-900 shadow-xs outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/40 dark:border-neutral-700 dark:bg-neutral-950 dark:text-neutral-100"
                    aria-invalid={fieldErrors.slug ? true : undefined}
                  />
                </div>
                <p className="text-sm text-neutral-600 dark:text-neutral-400">
                  Lowercase letters, numbers, and hyphens. Appears in URLs like
                  <span className="ml-1 font-mono text-neutral-800 dark:text-neutral-200">
                    cmux.app/{slugPreview}
                  </span>
                </p>
                {fieldErrors.slug ? (
                  <p className="text-sm text-red-500 dark:text-red-400">{fieldErrors.slug}</p>
                ) : null}
              </div>

              <div className="flex items-center justify-end gap-2">
                <Button type="submit">Next</Button>
              </div>
            </form>
          ) : (
            <form onSubmit={handleCreateTeam} className="mt-6 space-y-6">
              <div className="rounded-lg border border-neutral-200 bg-neutral-50 px-4 py-3 dark:border-neutral-800 dark:bg-neutral-900/60">
                <div className="text-sm font-medium text-neutral-800 dark:text-neutral-200">
                  {displayName.trim() || "New team"}
                </div>
                <div className="text-sm text-neutral-600 dark:text-neutral-400">
                  cmux.app/{slugPreview}
                </div>
              </div>

              <div className="space-y-2">
                <label className="block text-sm font-medium text-neutral-800 dark:text-neutral-200">
                  Invite teammates (optional)
                </label>
                <textarea
                  value={inviteInput}
                  onChange={(event) => setInviteInput(event.target.value)}
                  placeholder="Enter email addresses separated by commas or spaces"
                  className="w-full min-h-[120px] rounded-lg border border-neutral-300 bg-white px-3 py-2 text-sm text-neutral-900 shadow-xs outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/40 dark:border-neutral-700 dark:bg-neutral-950 dark:text-neutral-100"
                />
                <p className="text-sm text-neutral-600 dark:text-neutral-400">
                  We’ll send invites after your team is created. You can skip this for now.
                </p>
              </div>

              {error ? (
                <div className="rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-600 dark:border-red-900/60 dark:bg-red-950/40 dark:text-red-400">
                  {error}
                </div>
              ) : null}

              <div className="flex items-center justify-between gap-2">
                <Button type="button" variant="ghost" onClick={handleBack} disabled={loading}>
                  Back
                </Button>
                <Button type="submit" disabled={loading}>
                  {loading ? "Creating..." : "Create team"}
                </Button>
              </div>
            </form>
          )}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

function slugify(input: string): string {
  return input
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+/, "")
    .replace(/-+$/, "");
}

function normalizeSlug(input: string): string {
  return input.trim().toLowerCase();
}

function sanitizeSlugInput(input: string): string {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+/, "")
    .replace(/-+$/, "");
}

function validateSlug(slug: string): string | null {
  if (slug.length === 0) {
    return "Enter a slug for your team";
  }
  if (slug.length < 3 || slug.length > 48) {
    return "Slug must be 3–48 characters long";
  }
  if (!/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(slug)) {
    return "Slug can use lowercase letters, numbers, and hyphens";
  }
  return null;
}

function parseInviteEmails(input: string): string[] {
  return input
    .split(/[\s,]+/)
    .map((email) => email.trim())
    .filter((email) => email.length > 0);
}

function extractMetadata(value: unknown): Record<string, unknown> {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return { ...(value as Record<string, unknown>) };
  }
  return {};
}
