import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import * as Dialog from "@radix-ui/react-dialog";
import { X } from "lucide-react";
import React from "react";

export interface CreateTeamFormValues {
  name: string;
  slug: string;
  invites: string[];
}

interface CreateTeamDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSubmit: (values: CreateTeamFormValues) => Promise<void> | void;
  isSubmitting: boolean;
  error?: string | null;
}

function sanitizeSlugInput(value: string): string {
  const lower = value.toLowerCase();
  const replaced = lower.replace(/[^a-z0-9-]+/g, "-");
  const collapsed = replaced.replace(/-+/g, "-");
  const trimmedEdges = collapsed.replace(/^-+/, "").replace(/-+$/, "");
  return trimmedEdges.slice(0, 48);
}

function normalizeSlug(value: string): string {
  return sanitizeSlugInput(value.trim());
}

function generateSlugFromName(name: string): string {
  return sanitizeSlugInput(name.trim());
}

function parseInvites(raw: string): string[] {
  const segments = raw
    .split(/[\s,]+/)
    .map((segment) => segment.trim())
    .filter((segment) => segment.length > 0);
  const unique = Array.from(new Set(segments));
  return unique;
}

export function CreateTeamDialog({
  open,
  onOpenChange,
  onSubmit,
  isSubmitting,
  error,
}: CreateTeamDialogProps) {
  const [name, setName] = React.useState("");
  const [slug, setSlug] = React.useState("");
  const [invitesText, setInvitesText] = React.useState("");
  const [slugManuallyEdited, setSlugManuallyEdited] = React.useState(false);
  const [nameError, setNameError] = React.useState<string | null>(null);
  const [slugError, setSlugError] = React.useState<string | null>(null);

  const nameFieldId = React.useId();
  const slugFieldId = React.useId();
  const invitesFieldId = React.useId();
  const nameHintId = `${nameFieldId}-hint`;
  const nameErrorId = `${nameFieldId}-error`;
  const slugHintId = `${slugFieldId}-hint`;
  const slugErrorId = `${slugFieldId}-error`;
  const invitesHintId = `${invitesFieldId}-hint`;

  React.useEffect(() => {
    if (!open) {
      setName("");
      setSlug("");
      setInvitesText("");
      setSlugManuallyEdited(false);
      setNameError(null);
      setSlugError(null);
    }
  }, [open]);

  React.useEffect(() => {
    if (slugManuallyEdited) {
      return;
    }
    const autoSlug = generateSlugFromName(name);
    if (autoSlug !== slug) {
      setSlug(autoSlug);
    }
  }, [name, slug, slugManuallyEdited]);

  const handleSlugChange = (value: string) => {
    const sanitized = sanitizeSlugInput(value);
    setSlug(sanitized);
    const auto = generateSlugFromName(name);
    if (sanitized.length === 0 || sanitized === auto) {
      setSlugManuallyEdited(false);
    } else {
      setSlugManuallyEdited(true);
    }
    if (slugError && sanitized.length > 0) {
      setSlugError(null);
    }
  };

  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();

    const trimmedName = name.trim();
    const normalizedSlug = normalizeSlug(slug);

    let hasError = false;
    if (trimmedName.length === 0) {
      setNameError("Enter a team name");
      hasError = true;
    } else if (trimmedName.length > 32) {
      setNameError("Name must be at most 32 characters");
      hasError = true;
    } else {
      setNameError(null);
    }

    if (normalizedSlug.length === 0) {
      setSlugError("Enter a team slug");
      hasError = true;
    } else if (normalizedSlug.length < 3 || normalizedSlug.length > 48) {
      setSlugError("Slug must be 3-48 characters");
      hasError = true;
    } else if (!/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(normalizedSlug)) {
      setSlugError(
        "Use lowercase letters, numbers, and hyphens. Start and end with a letter or number."
      );
      hasError = true;
    } else {
      setSlugError(null);
    }

    if (hasError) {
      setSlug(normalizedSlug);
      return;
    }

    setSlug(normalizedSlug);
    const invites = parseInvites(invitesText);
    void onSubmit({
      name: trimmedName,
      slug: normalizedSlug,
      invites,
    });
  };

  const helperText = slug.length > 0 ? `/${slug}/dashboard` : "/your-team/dashboard";

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-neutral-950/60 backdrop-blur-sm" />
        <Dialog.Content
          className={cn(
            "fixed left-1/2 top-1/2 z-50 w-full max-w-xl -translate-x-1/2 -translate-y-1/2 rounded-2xl border",
            "border-neutral-200 bg-white shadow-2xl focus:outline-none dark:border-neutral-800 dark:bg-neutral-900"
          )}
        >
          <form onSubmit={handleSubmit} className="flex flex-col">
            <div className="flex items-start justify-between gap-4 px-6 pt-6">
              <div>
                <Dialog.Title className="text-lg font-semibold text-neutral-900 dark:text-neutral-50">
                  Create a team
                </Dialog.Title>
                <Dialog.Description className="mt-1 text-sm text-neutral-600 dark:text-neutral-400">
                  Name your workspace, choose a URL slug, and optionally invite teammates.
                </Dialog.Description>
              </div>
              <Dialog.Close asChild>
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  className="text-neutral-500 hover:text-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-100"
                  disabled={isSubmitting}
                  aria-label="Close"
                >
                  <X className="size-4" />
                </Button>
              </Dialog.Close>
            </div>

            <div className="px-6 py-4 space-y-4">
              <div className="space-y-2">
                <label
                  htmlFor={nameFieldId}
                  className="block text-sm font-medium text-neutral-800 dark:text-neutral-200"
                >
                  Team name
                </label>
                <input
                  id={nameFieldId}
                  type="text"
                  value={name}
                  onChange={(event) => {
                    const next = event.target.value;
                    setName(next);
                    const trimmed = next.trim();
                    if (
                      nameError &&
                      trimmed.length > 0 &&
                      trimmed.length <= 32
                    ) {
                      setNameError(null);
                    }
                  }}
                  onBlur={() => {
                    if (nameError && name.trim().length > 0 && name.trim().length <= 32) {
                      setNameError(null);
                    }
                  }}
                  autoFocus
                  disabled={isSubmitting}
                  aria-invalid={nameError ? true : undefined}
                  aria-describedby={nameError ? nameErrorId : nameHintId}
                  className={cn(
                    "w-full rounded-lg border px-3 py-2 text-sm shadow-xs focus:outline-none focus:ring-2",
                    "border-neutral-200 bg-white text-neutral-900 focus:border-primary focus:ring-primary/20",
                    "dark:border-neutral-800 dark:bg-neutral-950 dark:text-neutral-50 dark:focus:border-primary"
                  )}
                  placeholder="My product team"
                />
                {nameError ? (
                  <p
                    id={nameErrorId}
                    className="text-sm text-destructive dark:text-red-400"
                  >
                    {nameError}
                  </p>
                ) : (
                  <p
                    id={nameHintId}
                    className="text-xs text-neutral-500 dark:text-neutral-400"
                  >
                    Up to 32 characters. You can change this later.
                  </p>
                )}
              </div>

              <div className="space-y-2">
                <label
                  htmlFor={slugFieldId}
                  className="block text-sm font-medium text-neutral-800 dark:text-neutral-200"
                >
                  Team slug
                </label>
                <input
                  id={slugFieldId}
                  type="text"
                  value={slug}
                  onChange={(event) => handleSlugChange(event.target.value)}
                  onBlur={() => {
                    const normalized = normalizeSlug(slug);
                    handleSlugChange(normalized);
                  }}
                  disabled={isSubmitting}
                  aria-invalid={slugError ? true : undefined}
                  aria-describedby={slugError ? slugErrorId : slugHintId}
                  className={cn(
                    "w-full rounded-lg border px-3 py-2 text-sm shadow-xs focus:outline-none focus:ring-2",
                    "border-neutral-200 bg-white text-neutral-900 focus:border-primary focus:ring-primary/20",
                    "dark:border-neutral-800 dark:bg-neutral-950 dark:text-neutral-50 dark:focus:border-primary"
                  )}
                  placeholder="my-team"
                />
                {slugError ? (
                  <p
                    id={slugErrorId}
                    className="text-sm text-destructive dark:text-red-400"
                  >
                    {slugError}
                  </p>
                ) : (
                  <p
                    id={slugHintId}
                    className="text-xs text-neutral-500 dark:text-neutral-400"
                  >
                    Lowercase letters, numbers, and hyphens. This becomes your URL: {helperText}
                  </p>
                )}
              </div>

              <div className="space-y-2">
                <label
                  htmlFor={invitesFieldId}
                  className="block text-sm font-medium text-neutral-800 dark:text-neutral-200"
                >
                  Invite teammates (optional)
                </label>
                <textarea
                  id={invitesFieldId}
                  value={invitesText}
                  onChange={(event) => setInvitesText(event.target.value)}
                  disabled={isSubmitting}
                  rows={3}
                  aria-describedby={invitesHintId}
                  className={cn(
                    "w-full rounded-lg border px-3 py-2 text-sm shadow-xs focus:outline-none focus:ring-2",
                    "border-neutral-200 bg-white text-neutral-900 focus:border-primary focus:ring-primary/20",
                    "dark:border-neutral-800 dark:bg-neutral-950 dark:text-neutral-50 dark:focus:border-primary"
                  )}
                  placeholder="alice@example.com, bob@example.com"
                />
                <p id={invitesHintId} className="text-xs text-neutral-500 dark:text-neutral-400">
                  Separate emails with commas or new lines. We'll send invitations after the team is created.
                </p>
              </div>

              {error ? (
                <div
                  role="alert"
                  className="rounded-lg border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive dark:border-red-800/40 dark:bg-red-900/20 dark:text-red-300"
                >
                  {error}
                </div>
              ) : null}
            </div>

            <div className="flex items-center justify-end gap-2 border-t border-neutral-200 px-6 py-4 dark:border-neutral-800">
              <Dialog.Close asChild>
                <Button type="button" variant="outline" disabled={isSubmitting}>
                  Cancel
                </Button>
              </Dialog.Close>
              <Button type="submit" disabled={isSubmitting}>
                {isSubmitting ? "Creating..." : "Create team"}
              </Button>
            </div>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
