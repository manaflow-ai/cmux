
/*
   This file is part of Valgrind, a dynamic binary instrumentation
   framework.

   Copyright (C) 2000-2005 Julian Seward
      jseward@acm.org
   Copyright (C) 2018-2021 Paul Floyd
      pjfloyd@wanadoo.fr

   This program is free software; you can redistribute it and/or
   modify it under the terms of the GNU General Public License as
   published by the Free Software Foundation; either version 2 of the
   License, or (at your option) any later version.

   This program is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, see <http://www.gnu.org/licenses/>.

   The GNU General Public License is contained in the file COPYING.
*/

#ifndef VKI_UNISTD_FREEBSD_H
#define VKI_UNISTD_FREEBSD_H

#include "config.h"

// this is the syscall format used by e.g., libc functions like 'write'
// this is the one used 99.999% of the time
// the two others are only for experimental or testing use
// (but we use them in the scalar tests).
#define VG_FREEBSD_SYSCALL_STD 0
// this is the syscall format used by 'syscall'
#define VG_FREEBSD_SYSCALL0    1
// this is the syscall format used by '__syscall'
// it is the same as VG_FREEBSD_SYSCALL0 except that
// it ensures that 64bit argument alignment is correct
// that makes no difference for amd64, x86 not sure
#define VG_FREEBSD_SYSCALL198  2

// From sys/syscall.h

// @todo PJF ugly leading double underscores
// and why use the Linux style when FreeBSD uses SYS_[name]?
// I suppose that makes the generic code easier

#define __NR_syscall             0
#define __NR_exit                1
#define __NR_fork                2
#define __NR_read                3
#define __NR_write               4
#define __NR_open                5
#define __NR_close               6
#define __NR_wait4               7
/* old creat                     8 */
#define __NR_link                9
#define __NR_unlink              10
/* obs execv                     11 */
#define __NR_chdir               12
#define __NR_fchdir              13
#define __NR_freebsd11_mknod     14
#define __NR_chmod               15
#define __NR_chown               16
#define __NR_break               17
/* freebsd4 getfsstat            18 */
/* old lseek                     19 */
#define __NR_getpid              20
#define __NR_mount               21
#define __NR_unmount             22
#define __NR_setuid              23
#define __NR_getuid              24
#define __NR_geteuid             25
#define __NR_ptrace              26
#define __NR_recvmsg             27
#define __NR_sendmsg             28
#define __NR_recvfrom            29
#define __NR_accept              30
#define __NR_getpeername         31
#define __NR_getsockname         32
#define __NR_access              33
#define __NR_chflags             34
#define __NR_fchflags            35
#define __NR_sync                36
#define __NR_kill                37
/* old stat                      38 */
#define __NR_getppid             39
/* old lstat                     40 */
#define __NR_dup                 41
#define __NR_freebsd10_pipe      42
#define __NR_getegid             43
#define __NR_profil              44
#define __NR_ktrace              45
/* old sigaction                 46 */
#define __NR_getgid              47
/* old sigprocmask               48 */
#define __NR_getlogin            49
#define __NR_setlogin            50
#define __NR_acct                51
/* old sigpending                52 */
#define __NR_sigaltstack         53
#define __NR_ioctl               54
#define __NR_reboot              55
#define __NR_revoke              56
#define __NR_symlink             57
#define __NR_readlink            58
#define __NR_execve              59
#define __NR_umask               60
#define __NR_chroot              61
/* old fstat                     62 */
/* old getkerninfo               63 */
/* old getpagesize               64 */
#define __NR_msync               65
#define __NR_vfork               66
/* obs vread                     67 */
/* obs vwrite                    68 */
#define __NR_sbrk                69
#define __NR_sstk                70
/* old mmap                      71 */
#define __NR_vadvise             72
#define __NR_munmap              73
#define __NR_mprotect            74
#define __NR_madvise             75
/* obs vhangup                   76 */
/* obs vlimit                    77 */
#define __NR_mincore             78
#define __NR_getgroups           79
#define __NR_setgroups           80
#define __NR_getpgrp             81
#define __NR_setpgid             82
#define __NR_setitimer           83
#define __NR_swapon              85
#define __NR_getitimer           86
/* old gethostname               87 */
/* old sethostname               88 */
#define __NR_getdtablesize       89
#define __NR_dup2                90
#define __NR_fcntl               92
#define __NR_select              93
#define __NR_fsync               95
#define __NR_setpriority         96
#define __NR_socket              97
#define __NR_connect             98
/* old accept                    99 */
#define __NR_getpriority         100
/* old send                      101 */
/* old recv                      102 */
/* old sigreturn                 103 */
#define __NR_bind                104
#define __NR_setsockopt          105
#define __NR_listen              106
/* obs vtimes                    107 */
/* old sigvec                    108 */
/* old sigblock                  109 */
/* old sigsetmask                110 */
/* old sigsuspend                111 */
/* old sigstack                  112 */
/* old recvmsg                   113 */
/* old sendmsg                   114 */
/* obs vtrace                    115 */
#define __NR_gettimeofday        116
#define __NR_getrusage           117
#define __NR_getsockopt          118
#define __NR_readv               120
#define __NR_writev              121
#define __NR_settimeofday        122
#define __NR_fchown              123
#define __NR_fchmod              124
#define __NR_setreuid            126
#define __NR_setregid            127
#define __NR_rename              128
#define __NR_flock               131
#define __NR_mkfifo              132
#define __NR_sendto              133
#define __NR_shutdown            134
#define __NR_socketpair          135
#define __NR_mkdir               136
#define __NR_rmdir               137
#define __NR_utimes              138
/* obs freebsd sigreturn         139 */
#define __NR_adjtime             140
/* old getpeername               141 */
/* old gethostid                 142 */
/* old sethostid                 143 */
/* old getrlimit                 144 */
/* old setrlimit                 145 */
/* old killpg                    146 */
#define __NR_setsid              147
#define __NR_quotactl            148
/* old quota                     149 */
/* old getsockname               150  */
#define __NR_nlm_syscall         154
#define __NR_nfssvc              155
/* old getdirentries             156 */

#if (FREEBSD_VERS <= FREEBSD_10)
// these were removed in FreeBSD 11
#define __NR_freebsd4_statfs     157
#define __NR_freebsd4_fstatfs    158
#endif
#define __NR_lgetfh              160
#define __NR_getfh               161

#if (FREEBSD_VERS <= FREEBSD_10)
#define __NR_freebsd4_getdomainname 162
#define __NR_freebsd4_setdomainname 163
#define __NR_freebsd4_uname      164
#endif

#define __NR_sysarch             165
#define __NR_rtprio              166
#define __NR_semsys              169
#define __NR_msgsys              170
#define __NR_shmsys              171
#if (FREEBSD_VERS <= FREEBSD_10)
#define __NR_freebsd6_pread      173
#define __NR_freebsd6_pwrite     174
#endif
#define __NR_setfib              175
#define __NR_ntp_adjtime         176
#define __NR_setgid              181
#define __NR_setegid             182
#define __NR_seteuid             183

#if (FREEBSD_VERS >= FREEBSD_12)
#define __NR_freebsd11_stat      188
#define __NR_freebsd11_fstat     189
#define __NR_freebsd11_lstat     190
#else
#define __NR_stat                188
#define __NR_fstat               189
#define __NR_lstat               190
#endif

#define __NR_pathconf            191
#define __NR_fpathconf           192
#define __NR_getrlimit           194
#define __NR_setrlimit           195

#if (FREEBSD_VERS >= FREEBSD_12)
#define __NR_freebsd11_getdirentries 196
#else
#define __NR_getdirentries       196
#endif
#if (FREEBSD_VERS <= FREEBSD_10)
#define __NR_freebsd6_mmap       197
#endif
#define __NR___syscall           198
#if (FREEBSD_VERS <= FREEBSD_10)
#define __NR_freebsd6_lseek      199
#define __NR_freebsd6_truncate   200
#define __NR_freebsd6_ftruncate  201
#endif
#define __NR___sysctl            202
#define __NR_mlock               203
#define __NR_munlock             204
#define __NR_undelete            205
#define __NR_futimes             206
#define __NR_getpgid             207
#define __NR_poll                209
#define __NR_freebsd7___semctl   220
#define __NR_semget              221
#define __NR_semop               222
/* obs semconfig                 223 */
#define __NR_freebsd7_msgctl     224
#define __NR_msgget              225
#define __NR_msgsnd              226
#define __NR_msgrcv              227
#define __NR_shmat               228
#define __NR_freebsd7_shmctl     229
#define __NR_shmdt               230
#define __NR_shmget              231
#define __NR_clock_gettime       232
#define __NR_clock_settime       233
#define __NR_clock_getres        234
#define __NR_ktimer_create       235
#define __NR_ktimer_delete       236
#define __NR_ktimer_settime      237
#define __NR_ktimer_gettime      238
#define __NR_ktimer_getoverrun   239
#define __NR_nanosleep           240
#define __NR_ffclock_getcounter  241
#define __NR_ffclock_setestimate 242
#define __NR_ffclock_getestimate 243
#define __NR_clock_nanosleep     244
#define __NR_clock_getcpuclockid2 247
#define __NR_ntp_gettime         248

#define __NR_minherit            250
#define __NR_rfork               251
/* ons openbsd_poll              252 */
#define __NR_issetugid           253
#define __NR_lchown              254
#define __NR_aio_read            255
#define __NR_aio_write           256
#define __NR_lio_listio          257
#define __NR_freebsd11_getdents  272
#define __NR_lchmod              274
/* obs netbsd_lchown             275 */
#define __NR_lutimes             276
/* obs netbsd_msync              277 */

#if (FREEBSD_VERS >= FREEBSD_12)
#define __NR_freebsd11_nstat     278
#define __NR_freebsd11_nfstat    279
#define __NR_freebsd11_nlstat    280
#else
#define __NR_nstat               278
#define __NR_nfstat              279
#define __NR_nlstat              280
#endif
#define __NR_preadv              289
#define __NR_pwritev             290

#if (FREEBSD_VERS <= FREEBSD_10)
#define __NR_freebsd4_fhstatfs   297
#endif

#define __NR_fhopen              298

#if (FREEBSD_VERS >= FREEBSD_12)
#define __NR_freebsd11_fhstat    299
#else
#define __NR_fhstat              299
#endif

#define __NR_modnext             300
#define __NR_modstat             301
#define __NR_modfnext            302
#define __NR_modfind             303
#define __NR_kldload             304
#define __NR_kldunload           305
#define __NR_kldfind             306
#define __NR_kldnext             307
#define __NR_kldstat             308
#define __NR_kldfirstmod         309
#define __NR_getsid              310
#define __NR_setresuid           311
#define __NR_setresgid           312
/* obs signanosleep              313 */
#define __NR_aio_return          314
#define __NR_aio_suspend         315
#define __NR_aio_cancel          316
#define __NR_aio_error           317
#if (FREEBSD_VERS <= FREEBSD_10)
#define __NR_oaio_read           318
#define __NR_oaio_write          319
#define __NR_olio_listio         320
#endif
#define __NR_yield               321
/* obs thr_sleep                 323 */
/* obs thr_wakeup                324 */
#define __NR_mlockall            324
#define __NR_munlockall          325
#define __NR___getcwd            326
#define __NR_sched_setparam      327
#define __NR_sched_getparam      328
#define __NR_sched_setscheduler  329
#define __NR_sched_getscheduler  330
#define __NR_sched_yield         331
#define __NR_sched_get_priority_max 332
#define __NR_sched_get_priority_min 333
#define __NR_sched_rr_get_interval 334
#define __NR_utrace              335
#if (FREEBSD_VERS <= FREEBSD_10)
#define __NR_freebsd4_sendfile   342
#endif
#define __NR_kldsym              337
#define __NR_jail                338
#define __NR_sigprocmask         340
#define __NR_sigsuspend          341
#if (FREEBSD_VERS <= FREEBSD_10)
#define __NR_freebsd4_sigaction  342
#endif
#define __NR_sigpending          343
#if (FREEBSD_VERS <= FREEBSD_10)
#define __NR_freebsd4_sigreturn  344
#endif
#define __NR_sigtimedwait        345
#define __NR_sigwaitinfo         346
#define __NR___acl_get_file      347
#define __NR___acl_set_file      348
#define __NR___acl_get_fd        349
#define __NR___acl_set_fd        350
#define __NR___acl_delete_file   351
#define __NR___acl_delete_fd     352
#define __NR___acl_aclcheck_file 353
#define __NR___acl_aclcheck_fd   354
#define __NR_extattrctl          355
#define __NR_extattr_set_file    356
#define __NR_extattr_get_file    357
#define __NR_extattr_delete_file 358
#define __NR_aio_waitcomplete    359
#define __NR_getresuid           360
#define __NR_getresgid           361
#define __NR_kqueue              362

#if (FREEBSD_VERS >= FREEBSD_12)
#define __NR_freebsd11_kevent    363
#else
#define __NR_kevent              363
#endif
/* obs __cap_get_proc            364 */
/* obs __cap_set_proc            365 */
/* obs __cap_get_fd              366 */
/* obs __cap_get_file            367 */
/* obs __cap_set_fd              368 */
/* obs __cap_set_file            369 */

#define __NR_extattr_set_fd      371
#define __NR_extattr_get_fd      372
#define __NR_extattr_delete_fd   373
#define __NR___setugid           374
/* obs nfsclnt                   375 */
#define __NR_eaccess             376
#define __NR_nmount              378
/* obs kse_exit                  379 */
/* obs kse_wakeup                380 */
/* obs kse_create                381 */
/* obs kse_thr_interrupt         382 */
/* obs kse_release               383 */
#define __NR___mac_get_proc      384
#define __NR___mac_set_proc      385
#define __NR___mac_get_fd        386
#define __NR___mac_get_file      387
#define __NR___mac_set_fd        388
#define __NR___mac_set_file      389
#define __NR_kenv                390
#define __NR_lchflags            391
#define __NR_uuidgen             392
#define __NR_sendfile            393
#define __NR_mac_syscall         394

#if (FREEBSD_VERS >= FREEBSD_12)
#define __NR_freebsd11_getfsstat 395
#define __NR_freebsd11_statfs    396
#define __NR_freebsd11_fstatfs   397
#define __NR_freebsd11_fhstatfs  398
#else
#define __NR_getfsstat           395
#define __NR_statfs              396
#define __NR_fstatfs             397
#define __NR_fhstatfs            398
#endif

#define __NR_ksem_close          400
#define __NR_ksem_post           401
#define __NR_ksem_wait           402
#define __NR_ksem_trywait        403
#define __NR_ksem_init           404
#define __NR_ksem_open           405
#define __NR_ksem_unlink         406
#define __NR_ksem_getvalue       407
#define __NR_ksem_destroy        408
#define __NR___mac_get_pid       409
#define __NR___mac_get_link      410
#define __NR___mac_set_link      411
#define __NR_extattr_set_link    412
#define __NR_extattr_get_link    413
#define __NR_extattr_delete_link 414
#define __NR___mac_execve        415
#define __NR_sigaction           416
#define __NR_sigreturn           417
#define __NR_getcontext          421
#define __NR_setcontext          422
#define __NR_swapcontext         423
#if (FREEBSD_VERS >= FREEBSD_13_1)
#define __NR_freebsd13_swapoff   424
#else
#define __NR_swapoff             424
#endif
#define __NR___acl_get_link      425
#define __NR___acl_set_link      426
#define __NR___acl_delete_link   427
#define __NR___acl_aclcheck_link 428
#define __NR_sigwait             429
#define __NR_thr_create          430
#define __NR_thr_exit            431
#define __NR_thr_self            432
#define __NR_thr_kill            433
#define __NR__umtx_lock          434
#define __NR__umtx_unlock        435
#define __NR_jail_attach         436
#define __NR_extattr_list_fd     437
#define __NR_extattr_list_file   438
#define __NR_extattr_list_link   439
/* obs kse_switchin              440 */
#define __NR_ksem_timedwait      441
#define __NR_thr_suspend         442
#define __NR_thr_wake            443
#define __NR_kldunloadf          444
#define __NR_audit               445
#define __NR_auditon             446
#define __NR_getauid             447
#define __NR_setauid             448
#define __NR_getaudit            449
#define __NR_setaudit            450
#define __NR_getaudit_addr       451
#define __NR_setaudit_addr       452
#define __NR_auditctl            453
#define __NR__umtx_op            454
#define __NR_thr_new             455
#define __NR_sigqueue            456
#define __NR_kmq_open            457
#define __NR_kmq_setattr         458
#define __NR_kmq_timedreceive    459
#define __NR_kmq_timedsend       460
#define __NR_kmq_notify          461
#define __NR_kmq_unlink          462
#define __NR_abort2              463
#define __NR_thr_set_name        464
#define __NR_aio_fsync           465
#define __NR_rtprio_thread       466
#define __NR_nosys467            467
#define __NR_nosys468            468
#define __NR___getpath_fromfd    469
#define __NR___getpath_fromaddr  470
#define __NR_sctp_peeloff        471
#define __NR_sctp_generic_sendmsg 472
#define __NR_sctp_generic_sendmsg_iov 473
#define __NR_sctp_generic_recvmsg 474
#define __NR_pread               475
#define __NR_pwrite              476
#define __NR_mmap                477
#define __NR_lseek               478
#define __NR_truncate            479
#define __NR_ftruncate           480
#define __NR_thr_kill2           481

// __NR_freebsd12_shm_open from FreeBSD 13
#define __NR_shm_open            482
#define __NR_shm_unlink          483
#define __NR_cpuset              484
#define __NR_cpuset_setid        485
#define __NR_cpuset_getid        486
#define __NR_cpuset_getaffinity  487
#define __NR_cpuset_setaffinity  488
#define __NR_faccessat           489
#define __NR_fchmodat            490
#define __NR_fchownat            491
#define __NR_fexecve             492

#if (FREEBSD_VERS >= FREEBSD_12)
#define __NR_freebsd11_fstatat   493
#else
#define __NR_fstatat             493
#endif

#define __NR_futimesat           494
#define __NR_linkat              495
#define __NR_mkdirat             496
#define __NR_mkfifoat            497

#if (FREEBSD_VERS >= FREEBSD_12)
#define __NR_freebsd11_mknodat   498
#else
#define __NR_mknodat             498
#endif

#define __NR_openat              499
#define __NR_readlinkat          500
#define __NR_renameat            501
#define __NR_symlinkat           502
#define __NR_unlinkat            503
#define __NR_posix_openpt        504
#define __NR_jail_get            506
#define __NR_jail_set            507
#define __NR_jail_remove         508

// __NR_freebsd12_closefrom from FreeBSD 13
#define __NR_closefrom           509
#define __NR___semctl            510
#define __NR_msgctl              511
#define __NR_shmctl              512
#define __NR_lpathconf           513
/* obs cap_new                   514 */
#define __NR___cap_rights_get    515
#define __NR_cap_enter           516
#define __NR_cap_getmode         517
#define __NR_pdfork              518
#define __NR_pdkill              519
#define __NR_pdgetpid            520
#define __NR_pselect             522
#define __NR_getloginclass       523
#define __NR_setloginclass       524
#define __NR_rctl_get_racct      525
#define __NR_rctl_get_rules      526
#define __NR_rctl_get_limits     527
#define __NR_rctl_add_rule       528
#define __NR_rctl_remove_rule    529
#define __NR_posix_fallocate     530
#define __NR_posix_fadvise       531
#define __NR_wait6               532
#define __NR_cap_rights_limit    533
#define __NR_cap_ioctls_limit    534
#define __NR_cap_ioctls_get      535
#define __NR_cap_fcntls_limit    536
#define __NR_cap_fcntls_get      537
#define __NR_bindat              538
#define __NR_connectat           539
#define __NR_chflagsat           540
#define __NR_accept4             541
#define __NR_pipe2               542
#define __NR_aio_mlock           543
#define __NR_procctl             544
#define __NR_ppoll               545
#define __NR_futimens            546
#define __NR_utimensat           547

/* obs numa_getaffinity          548 */
/* obs numa_setaffinity          549 */
#if (FREEBSD_VERS >= FREEBSD_11)

#define __NR_fdatasync           550

#endif // (FREEBSD_VERS >= FREEBSD_11)

#if (FREEBSD_VERS >= FREEBSD_12)

#define __NR_fstat               551
#define __NR_fstatat             552
#define __NR_fhstat              553
#define __NR_getdirentries       554
#define __NR_statfs              555
#define __NR_fstatfs             556
#define __NR_getfsstat           557
#define __NR_fhstatfs            558
#define __NR_mknodat             559
#define __NR_kevent              560
#define __NR_cpuset_getdomain    561
#define __NR_cpuset_setdomain    562
#define __NR_getrandom           563
#define __NR_getfhat             564
#define __NR_fhlink              565
#define __NR_fhlinkat            566
#define __NR_fhreadlink          567

#endif // (FREEBSD_VERS >= FREEBSD_12)

#if (FREEBSD_VERS >= FREEBSD_12_2)

#define __NR_funlinkat           568
#define __NR_copy_file_range     569
#define __NR___sysctlbyname      570
#if (FREEBSD_VERS >= FREEBSD_13_0)
#define __NR_shm_open2           571
#define __NR_shm_rename          572
#define __NR_sigfastblock        573
#define __NR___realpathat        574
#endif
#define __NR_close_range         575

#endif

#if (FREEBSD_VERS >= FREEBSD_13_0)

#define __NR_rpctls_syscall      576
#define __NR___specialfd         577
#define __NR_aio_writev          578
#define __NR_aio_readv           579

#endif

#if (FREEBSD_VERS >= FREEBSD_13_1)

#define __NR_fspacectl           580
#define __NR_sched_getcpu        581
#define __NR_swapoff             582

#endif

#if (FREEBSD_VERS >= FREEBSD_15)

#define __NR_kqueuex             583
#define __NR_membarrier          584
#define __NR_timerfd_create      585
#define __NR_timerfd_gettime     586
#define __NR_timerfd_settime     587

#endif

#define __NR_fake_sigreturn      1000

#endif /* VKI_UNISTD_FREEBSD_H */
